#if os(iOS)
import Combine
import UIKit

@MainActor
final class MainReaderScreenController: UIViewController {
    private var library: LibraryStore
    private var settings: AppSettings
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore
    private let sessionDefaults: UserDefaults
    private var pendingLaunchRestoreBookID: String?
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private let readerControllerFactory: (@MainActor (BookEntity, Bool) -> BookOpenScreenController)?
    private let openStageObserver: (@Sendable (String, UInt64) -> Void)?
    private lazy var listeningSession: ReaderListeningSession = ReaderListeningSession(
        player: player, playerPresentation: playerPresentation,
        conversionExecutor: conversionExecutor,
        currentBookID: { [weak self] in self?.currentBook?.id },
        openBook: { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.library.openBookFileAsync(id: id)
        },
        recordConversion: { [weak self] jobID, bookID in
            self?.library.recordConversion(jobId: jobID, for: bookID)
        },
        reportFailure: { [weak self] error in
            guard let self else { return }
            ReaderListeningAlerts.present(error, from: self, library: { [weak self] in self?.library })
        }
    )
    private var onBrowseLibrary: (() -> Void)?
    var onReaderChromeVisibilityChanged: ((Bool) -> Void)?
    var onReaderLoadingChanged: ((Bool) -> Void)?

    private let emptyPresentation = ReaderEmptyPresentation()
    private let readerNavigation = ReaderNavigationPresentation()
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceCancellable: AnyCancellable?
    private var readerController: BookOpenScreenController?
    private var readerBookID: String?
    private var openingReaderBookID: String?
    private var needsRenderAfterReaderOpen = false
    private var readerTopToNavigation: NSLayoutConstraint!
    private var readerTopToRoot: NSLayoutConstraint!
    /// Loading is a reader-content fact, not duplicated presentation state.
    var isLoadingBookContent: Bool { readerController?.isLoadingBookContent ?? false }

    private var currentBook: BookEntity? {
        guard let id = sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              !id.isEmpty else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    init(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore,
        onBrowseLibrary: (() -> Void)?,
        conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor = RustConversionCoordinator.executeStreaming,
        sessionDefaults: UserDefaults = .standard,
        readerControllerFactory: (@MainActor (BookEntity, Bool) -> BookOpenScreenController)? = nil,
        openStageObserver: (@Sendable (String, UInt64) -> Void)? = nil
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        self.onBrowseLibrary = onBrowseLibrary
        self.conversionExecutor = conversionExecutor
        self.sessionDefaults = sessionDefaults
        self.pendingLaunchRestoreBookID = sessionDefaults.string(
            forKey: ReaderSessionState.currentlyReadingBookIDKey
        )
        self.readerControllerFactory = readerControllerFactory
        self.openStageObserver = openStageObserver
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        readerNavigation.install(in: view, target: self, closeAction: #selector(closeReaderTapped))
        emptyPresentation.install(in: view, target: self,
                                  browseAction: #selector(browseLibraryTapped), listenAction: #selector(listenTapped))
        applyReaderColors()
        bindAppearance()
        bind()
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        readerNavigation.updateHeight(in: view)
    }

    func update(
        library: LibraryStore,
        settings: AppSettings,
        onBrowseLibrary: (() -> Void)?
    ) {
        self.library = library
        let settingsChanged = self.settings !== settings
        self.settings = settings
        self.onBrowseLibrary = onBrowseLibrary
        if isViewLoaded {
            if settingsChanged { bindAppearance() }
            applyReaderColors()
        }
        render()
    }

    private func bindAppearance() {
        appearanceCancellable = settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyReaderColors() }
    }

    private func applyReaderColors() {
        let style: UIUserInterfaceStyle
        switch settings.readerPreferredColorScheme {
        case .dark: style = .dark
        case .light: style = .light
        case nil: style = .unspecified
        }
        if overrideUserInterfaceStyle != style { overrideUserInterfaceStyle = style }
        let colors = settings.readerColors
        view.backgroundColor = colors.background
        view.tintColor = colors.link
        readerNavigation.readerNavigationBar.tintColor = colors.link
        emptyPresentation.applyColors(foreground: colors.foreground)
        // Keep the native transparent navigation appearance and system material.
    }

    private func bind() {
        listeningSession.observePlayback()
        player.restartReaderListening = { [weak self] chapter, ratio in
            guard let self, let book = self.currentBook,
                  self.sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == book.id,
                  self.player.isPlaybackForReaderBook(book.id)
                    || self.player.snapshot?.jobId == book.lastJobId,
                  self.listeningSession.isListening(to: book.id)
                    || self.player.snapshot?.chapterProgress?.contains(where: { ($0.textOffset ?? 0) > 0 }) == true else { return false }
            self.startListening(presentsFullPlayer: false, requestedChapter: chapter, requestedRatio: ratio)
            return true
        }

        library.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.autoClearMissingBookIfNeeded()
                self?.render()
            }
            .store(in: &cancellables)
    }

    private func render() {
        if let book = currentBook {
            showBook(book)
        } else {
            showEmptyState()
        }
        // Visible once a book is loaded (never for a never-converted book,
        // tapping it starts conversion in the background — mirrors the
        // macOS reader's "Play inicia a conversão/reprodução do livro").
        // Hidden while `BookOpenScreenController` is still parsing so the
        // open screen only ever shows cover+spinner, never chrome layered
        // on top of a blank/loading book.
        emptyPresentation.listenButton.isHidden = currentBook == nil || isLoadingBookContent
    }

    private func showEmptyState() {
        removeReaderControllerIfNeeded()
        emptyPresentation.isHidden = false
        emptyPresentation.listenButton.isHidden = true
        readerNavigation.readerNavigationBar.isHidden = true
        readerNavigation.readerNavigationBackground.isHidden = true
    }

    private func showBook(_ book: BookEntity) {
        emptyPresentation.isHidden = true
        readerNavigation.readerNavigationItem.title = book.resolvedTitle
        if readerController != nil, readerBookID == book.id {
            // The existing reader already owns this book. Re-loading it on
            // every library notification causes `loadBook()` to publish a
            // loading-state change, which re-enters `render()` indefinitely.
            return
        }
        guard openingReaderBookID == nil else {
            if openingReaderBookID != book.id { needsRenderAfterReaderOpen = true }
            return
        }
        openingReaderBookID = book.id
        let launchRestoreBookID = pendingLaunchRestoreBookID
        pendingLaunchRestoreBookID = nil
        let isLaunchRestore = launchRestoreBookID == book.id
        defer {
            openingReaderBookID = nil
            if needsRenderAfterReaderOpen {
                needsRenderAfterReaderOpen = false
                DispatchQueue.main.async { [weak self] in self?.render() }
            }
        }
        replaceActivePlaybackIfNeeded(for: book)
        // Reset immersive chrome only when creating/opening a different
        // reader. Playback/title updates during pagination re-enter render()
        // but must not make the hidden mini player visible again.
        onReaderChromeVisibilityChanged?(false)
        readerNavigation.readerNavigationBar.isHidden = false
        readerNavigation.readerNavigationBar.alpha = 1
        readerNavigation.readerNavigationBackground.isHidden = false
        readerNavigation.readerNavigationBackground.alpha = 1

        removeReaderControllerIfNeeded()

        let shouldDeferInitialGesture = !isLaunchRestore
        let reader = readerControllerFactory?(book, shouldDeferInitialGesture) ?? BookOpenScreenController(
            book: book,
            library: library,
            settings: settings,
            bookmarkStore: bookmarkStore,
            player: player,
            openStageObserver: openStageObserver,
            deferInitialReaderGestures: shouldDeferInitialGesture
        )
        reader.onLoadStateChanged = { [weak self] isLoading in
            guard let self else { return }
            self.emptyPresentation.listenButton.isHidden = self.currentBook == nil || isLoading
            self.onReaderLoadingChanged?(isLoading)
        }
        reader.onChromeVisibilityRequested = { [weak self] isHidden in
            guard let self else { return }
            self.onReaderChromeVisibilityChanged?(isHidden)
        }
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reader.view)
        readerTopToNavigation = reader.view.topAnchor.constraint(
            equalTo: readerNavigation.readerNavigationBar.bottomAnchor,
            constant: ReaderNavigationPresentation.readerContentTopSpacing
        )
        readerTopToRoot = reader.view.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerTopToNavigation,
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reader.didMove(toParent: self)
        view.bringSubviewToFront(readerNavigation.readerNavigationBackground)
        view.bringSubviewToFront(readerNavigation.readerNavigationBar)
        readerController = reader
        readerBookID = book.id
        readerNavigation.readerNavigationItem.rightBarButtonItems = reader.navigationBarButtonItems
        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: book.id,
            chapterIndex: ReaderProgressStore.read(bookId: book.id)?.chapterIndex ?? 0
        )

        // Do not mutate the library while rendering. `library.update` emits
        // `objectWillChange`, which calls `render()` again; updating
        // `lastOpenedAt` here creates an unbounded render/persist loop and
        // leaves the app at 100% CPU when a book is opened from the grid.
    }

    /// Opening a different book is a deliberate playback-context change.
    /// Keep the mini player, its queue, and the reader on one book instead
    /// of leaving an old AVQueuePlayer behind while the new reader updates
    /// the persisted book pointer.
    private func replaceActivePlaybackIfNeeded(for book: BookEntity) {
        if let listeningBookID = listeningSession.listeningBookID, listeningBookID != book.id { listeningSession.cancel() }
        let activeBookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let hasActivePlayback = player.snapshot != nil || player.hasLoadedAudioQueue || player.isConverting
        guard Self.shouldReplaceActivePlayback(
            activeBookID: activeBookID,
            incomingBookID: book.id,
            hasActivePlayback: hasActivePlayback
        ) else {
            return
        }

        listeningSession.cancel()
        player.stop()
        player.clearConversionState()
    }

    static func shouldReplaceActivePlayback(
        activeBookID: String?,
        incomingBookID: String,
        hasActivePlayback: Bool
    ) -> Bool {
        hasActivePlayback && activeBookID != incomingBookID
    }

    /// Keeps reader chrome visually independent from the paginated surface.
    /// Hiding chrome moves the reading surface to the screen edge. The child
    /// reader captures its visible text anchor before that reflow so the
    /// expanded page does not jump to a different passage.
    /// Root owns the mutable presentation state. Main only applies this
    /// immutable snapshot to its navigation constraints.
    @discardableResult
    func applyReaderPresentation(_ state: ReaderPresentationState) -> Bool {
        let chromeChanged = readerController?.applyChromeVisibility(state.isChromeHidden) ?? false
        let navigationChanged = (readerTopToNavigation?.isActive ?? false) != state.showsReaderNavigation
        readerNavigation.applyLayout(
            shouldShow: state.showsReaderNavigation,
            animated: false,
            commitsLayout: false,
            readerTopToNavigation: readerTopToNavigation,
            readerTopToRoot: readerTopToRoot,
            in: view
        )
        return chromeChanged || navigationChanged
    }

    /// Called by the root constraint coordinator after its single animation
    /// reaches final geometry. TextKit must only repaginate at this point.
    func completeReaderChromeLayoutTransition() {
        readerController?.completeViewportTransition()
    }

    /// The root transition coordinator captures the viewport before any host
    /// constraint changes. Main remains an adapter, not a second owner.
    func captureReaderViewportTransition() {
        readerController?.prepareForViewportTransition()
    }

    private func removeReaderControllerIfNeeded() {
        guard let readerController else { return }
        readerController.willMove(toParent: nil)
        readerController.view.removeFromSuperview()
        readerController.removeFromParent()
        self.readerController = nil
        self.readerBookID = nil
        readerTopToNavigation = nil
        readerTopToRoot = nil
        readerNavigation.readerNavigationItem.rightBarButtonItems = nil
    }

    private func autoClearMissingBookIfNeeded() {
        guard let id = sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              !library.books.contains(where: { $0.id == id }) else { return }
        ReaderSessionState.setCurrentlyReading(bookID: nil, defaults: sessionDefaults)
    }

    @objc
    private func closeReaderTapped() {
        ReaderSessionState.setCurrentlyReading(bookID: nil, defaults: sessionDefaults)
        onBrowseLibrary?()
    }

    @objc
    private func browseLibraryTapped() {
        onBrowseLibrary?()
    }

    // Mirrors `BookDetailScreenController.tapListen()` — the reader is now
    // the only iOS entry point for starting/resuming playback (Book Detail
    // no longer sits between the library grid and the reader).
    @objc
    private func listenTapped() {
        startListening(presentsFullPlayer: true)
    }

    /// The compact player's play button starts local conversion for a newly
    /// opened book. It deliberately keeps the reader visible; tapping the
    /// mini player's content remains the explicit route to the full player.
    func startListeningFromMiniPlayer() {
        startListening(presentsFullPlayer: false)
    }

    private func startListening(presentsFullPlayer: Bool, requestedChapter: Int? = nil, requestedRatio: Double? = nil) {
        guard let book = currentBook, book.fileType.supportsAudioConversion else { return }
        guard !isLoadingBookContent else { return }
        guard readerController == nil || readerBookID == book.id else { return }
        let priority = requestedChapter ?? readerController?.currentReaderChapterIndex
            ?? ReaderPlaybackPriorityChapter.index(bookID: book.id, defaults: sessionDefaults)
        // Capture the page before asynchronous file access or player teardown
        // can publish another chapter. Never borrow another book's anchor.
        let pageRatio: Double? = requestedRatio ?? {
            guard sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == book.id,
                  sessionDefaults.object(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey) as? Int == priority,
                  let ratio = sessionDefaults.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double,
                  ratio.isFinite, ratio > 0, ratio <= 1 else { return nil }
            return ratio
        }()
        let catalog = readerController?.playbackChapterCatalog
            ?? LocalFulltextCache.inMemoryPayload(bookId: book.id)?.chapters.map {
                (index: $0.zeroBasedEpubIndex, title: $0.displayTitle)
            } ?? []
        listeningSession.start(book: book, priority: priority, pageRatio: pageRatio,
                               catalog: catalog, conversionOptions: settings.conversionOptions,
                               presentsFullPlayer: presentsFullPlayer)
    }
}
#endif
