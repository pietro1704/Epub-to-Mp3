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
    private lazy var listeningSession = ReaderListeningSession(
        player: player, playerPresentation: playerPresentation, conversionExecutor: conversionExecutor,
        currentBookID: { [weak self] in self?.currentBook?.id }, library: { [weak self] in self?.library },
        reportFailure: { [weak self] in self?.reportListeningFailure($0) })
    private let listeningRecovery = ReaderListeningRecovery()
    private var languageResolutionTask: Task<Void, Never>?
    private var onBrowseLibrary: (() -> Void)?
    var onReaderChromeVisibilityChanged: ((Bool) -> Void)?
    var onReaderLoadingChanged: ((Bool) -> Void)?

    private let emptyPresentation = ReaderEmptyPresentation()
    private let readerNavigation = ReaderNavigationPresentation()
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceCancellable: AnyCancellable?
    private var readerController: BookOpenScreenController?
    private var readerBookID: String?
    private var playbackLocationRequest: (bookID: String, location: ReaderPlaybackLocation, generation: UUID)?
    private var openingReaderBookID: String?
    private var needsRenderAfterReaderOpen = false
    private var readerTopToNavigation: NSLayoutConstraint!
    private var readerTopToRoot: NSLayoutConstraint!
    /// Loading is a reader-content fact, not duplicated presentation state.
    var isLoadingBookContent: Bool { readerController?.isLoadingBookContent ?? false }

    func presentPlaybackContents(bookID: String, onSelect: @escaping (Int) -> Void,
                                 presentIn: @escaping (UIViewController) -> Void) -> Bool {
        guard readerBookID == bookID, let readerController, !readerController.isLoadingBookContent else { return false }
        readerController.contentsPresentation.presentTOC(onSelect: { [weak self] index in
            guard let self, self.readerBookID == bookID else { return }
            if self.player.snapshot?.playableChapters.contains(where: { $0.index == index && $0.downloadUrl != nil }) == true {
                onSelect(index)
            } else {
                self.startListening(presentsFullPlayer: false, requestedChapter: index)
            }
        }, presentIn: presentIn)
        return true
    }

    func openAtPlayback(bookID: String) async -> Bool {
        guard library.books.contains(where: { $0.id == bookID }),
              sessionDefaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey) == bookID,
              let location = ReaderPlaybackLocation(player: player) else { return false }
        let generation = player.remotePlaybackGeneration
        let snapshot = player.snapshot
        let isSpeech = player.isUsingSpeechFallback
        let readingBookID = currentBook?.id
        if isSpeech {
            guard player.isPlaybackForReaderBook(bookID) else { return false }
        } else {
            guard let snapshot else { return false }
            if !listeningSession.ownsPlaybackJob(snapshot.jobId, for: bookID) {
                guard await RetainedAudioOwner.resolve(snapshot)?.bookID == bookID else { return false }
            }
        }
        guard !Task.isCancelled, playerPresentation.showingFullPlayer,
              generation == player.remotePlaybackGeneration, snapshot?.jobId == player.snapshot?.jobId,
              isSpeech == player.isUsingSpeechFallback, currentBook?.id == readingBookID,
              sessionDefaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey) == bookID,
              library.books.contains(where: { $0.id == bookID }) else { return false }
        playbackLocationRequest = (bookID, location, generation)
        ReaderSessionState.setCurrentlyReading(bookID: bookID, defaults: sessionDefaults)
        render()
        applyPlaybackLocationIfReady()
        return true
    }

    private func applyPlaybackLocationIfReady() {
        guard let request = playbackLocationRequest else { return }
        guard currentBook?.id == request.bookID, request.generation == player.remotePlaybackGeneration else {
            playbackLocationRequest = nil
            return
        }
        guard readerBookID == request.bookID, let readerController, !readerController.isLoadingBookContent else { return }
        playbackLocationRequest = nil
        readerController.revealPlaybackLocation(request.location)
    }

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
            .sink { [weak self] _ in
                self?.applyReaderColors()
                self?.refreshBarReservation()
            }
    }

    /// The mini player appeared or went: let the reader recompute the room it leaves above the player.
    func refreshMiniPlayerReservation() { readerController?.view.setNeedsLayout() }

    /// Paginated layout reserves the top bar's space (see the 2026-11-23 ADR); scrolling layout overlays it.
    private func refreshBarReservation() {
        guard let readerTopToNavigation, let readerTopToRoot else { return }
        let reserves = settings.readerLayout == .paginated
        guard readerTopToNavigation.isActive != reserves else { return }
        NSLayoutConstraint.deactivate([readerTopToNavigation, readerTopToRoot])
        (reserves ? readerTopToNavigation : readerTopToRoot).isActive = true
        view.setNeedsLayout()
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

    private var warmedModelMenuBookID: String?

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

    private func warmModelMenu(for book: BookEntity) {
        guard warmedModelMenuBookID != book.id else { return }
        warmedModelMenuBookID = book.id
        let bookID = book.id
        ReaderModelSwitch.warm(request: ReaderVoicePickerRequest(settings: settings, library: library, player: player,
            currentContext: { [weak self] in
                guard let self, let book = currentBook, book.id == bookID else { return nil }
                return listeningSession.voicePickerContext(for: book)
            }, restart: { _, _ in }))
    }

    private func showBook(_ book: BookEntity) {
        warmModelMenu(for: book)
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
            if !isLoading { self.applyPlaybackLocationIfReady() }
        }
        reader.onPlaybackChapterEstimates = { [weak self] estimates in
            self?.listeningSession.updateChapterEstimates(estimates, for: book.id)
        }
        reader.onListenRequested = { [weak self] in self?.startListeningFromMiniPlayer() }
        reader.onVoiceModelsRequested = { [weak self] in self?.presentVoiceModels(bookID: book.id) }
        reader.onPDFPlaybackRequested = { [weak self] anchor in
            guard let self, self.currentBook?.id == book.id else { return }
            self.startListening(presentsFullPlayer: false, requestedChapter: anchor.chapterIndex, pdfAnchor: anchor)
        }
        reader.onSelectionPlaybackRequested = { [weak self] chapter, ratio in
            guard let self, self.currentBook?.id == book.id else { return }
            self.startListening(presentsFullPlayer: false, requestedChapter: chapter, requestedRatio: ratio)
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
            readerTopToRoot,
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reader.didMove(toParent: self)
        refreshBarReservation()
        view.bringSubviewToFront(readerNavigation.readerNavigationBackground)
        view.bringSubviewToFront(readerNavigation.readerNavigationBar)
        readerController = reader
        readerBookID = book.id
        reader.installNavigationBarButtonItems(in: readerNavigation.readerNavigationItem)
        if playbackLocationRequest?.bookID != book.id {
            PlaybackBindingStore.setCurrentlyPlaying(
                bookID: book.id,
                chapterIndex: ReaderProgressStore.read(bookId: book.id)?.chapterIndex ?? 0
            )
        }

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
    /// Chrome visibility changes only the overlay. The reading surface keeps
    /// the same physical-safe-area geometry and exact captured offset.
    @discardableResult
    func applyReaderPresentation(_ state: ReaderPresentationState, animated: Bool = false) -> Bool {
        let chromeChanged = readerController?.applyChromeVisibility(state.isChromeHidden) ?? false
        let reservesBar = settings.readerLayout == .paginated
        let navigationChanged = (readerTopToRoot?.isActive ?? false) == reservesBar
        readerNavigation.applyLayout(
            shouldShow: state.showsReaderNavigation,
            animated: animated,
            commitsLayout: false,
            readerTopToNavigation: readerTopToNavigation,
            readerTopToRoot: readerTopToRoot,
            reservesBar: reservesBar,
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
        readerController.installNavigationBarButtonItems(in: nil)
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

    // The reader is the only iOS entry point for starting/resuming playback
    // (Book Detail no longer sits between the library grid and the reader).
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

    func dismissListeningSession() {
        listeningRecovery.invalidate()
        listeningSession.cancel()
        player.pause()
        player.persistResumePoint(force: true)
        player.stop()
        player.clearConversionState()
    }

    private func reportListeningFailure(_ error: Error) {
        listeningRecovery.report(error, bookID: currentBook?.id, from: self,
            library: { [weak self] in self?.library }, currentBookID: { [weak self] in self?.currentBook?.id })
    }

    private func presentVoiceModels(bookID: String) {
        let request = ReaderVoicePickerRequest(settings: settings, library: library, player: player,
            currentContext: { [weak self] in
                guard let self, let book = currentBook, book.id == bookID else { return nil }
                return listeningSession.voicePickerContext(for: book)
            }) { [weak self] target, options in
                self?.startListening(presentsFullPlayer: false, requestedChapter: target.chapter,
                    optionsOverride: options, voiceChange: target)
            }
        ReaderVoicePickerPresentation.present(from: self, anchor: readerNavigation.readerNavigationItem.rightBarButtonItems?.first,
            request: request)
    }

    private func resolveLanguageModelThenStart(book: BookEntity, presentsFullPlayer: Bool, requestedChapter: Int?,
                                               requestedRatio: Double?, voiceChange: ReaderVoiceChange?,
                                               pdfAnchor: PDFReadingAudioMap.Anchor?) {
        languageResolutionTask?.cancel()
        languageResolutionTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await LanguageModelPlayback.outcome(
                for: book, settings: settings, hasExplicitSelection: false, dependencies: .live(library: library))
            let isCurrent = { [weak self] in self?.currentBook?.id == book.id && !Task.isCancelled }
            guard isCurrent() else { return }
            if case .missing = outcome {} else {
                // BOOK-LANGUAGE-PROFILE: warn about the profile's languages without a voice, before playing, never blocking.
                let dependencies = LanguageModelPlayback.Dependencies.live(library: library)
                Task { @MainActor [settings] in
                    PlatformFallbackNotice.showMissingProfileLanguages(
                        await LanguageModelPlayback.missingProfileLanguages(for: book, settings: settings, dependencies: dependencies))
                }
            }
            @MainActor func begin(options: ConversionOptions? = nil, recovery: TtsRecoveryAlert.Choice? = nil) {
                startListening(presentsFullPlayer: presentsFullPlayer, requestedChapter: requestedChapter,
                               requestedRatio: requestedRatio, recovery: recovery, optionsOverride: options,
                               voiceChange: voiceChange, pdfAnchor: pdfAnchor, languageResolved: true)
            }
            switch outcome {
            case .useSettings: begin()
            case let .use(preferences): begin(options: NarrationConversionOptions.current(for: preferences))
            case let .missing(language):
                // Never downloads on its own: the recovery alert asks (download, system voice, Models).
                let error = LanguageModelPlayback.missingModelError(language: language)
                if let choice = await TtsRecoveryAlert.choose(for: error, isCurrent: isCurrent), isCurrent() {
                    begin(recovery: choice)
                }
            }
        }
    }

    private func startListening(presentsFullPlayer: Bool, requestedChapter: Int? = nil, requestedRatio: Double? = nil, recovery: TtsRecoveryAlert.Choice? = nil,
                                optionsOverride: ConversionOptions? = nil, voiceChange: ReaderVoiceChange? = nil,
                                pdfAnchor: PDFReadingAudioMap.Anchor? = nil, languageResolved: Bool = false) {
        guard let book = currentBook, book.fileType.supportsAudioConversion else { return }
        guard !isLoadingBookContent else { return }
        guard readerController == nil || readerBookID == book.id else { return }
        MiniPlayerDismissal(defaults: sessionDefaults).allowPlayback(bookID: book.id)
        let priority = requestedChapter ?? readerController?.currentReaderChapterIndex
            ?? ReaderPlaybackPriorityChapter.index(bookID: book.id, defaults: sessionDefaults)
        let pageRatio = ReaderListeningStartLocation.pageRatio(bookID: book.id, chapter: priority,
            explicitRatio: requestedRatio, voiceChange: voiceChange, pdfAnchor: pdfAnchor, defaults: sessionDefaults)
        // The book's language is resolved first (analysis off the main thread, cached per book), unless
        // the listener made an explicit per-job selection or this is the retry after a recovery. The Play
        // intent (chapter and page) is captured now, not after the asynchronous resolution.
        if optionsOverride == nil, recovery == nil, !languageResolved {
            resolveLanguageModelThenStart(book: book, presentsFullPlayer: presentsFullPlayer, requestedChapter: priority,
                requestedRatio: pageRatio, voiceChange: voiceChange, pdfAnchor: pdfAnchor)
            return
        }
        let catalog = readerController?.playbackChapterCatalog
            ?? LocalFulltextCache.inMemoryPayload(bookId: book.id)?.chapters.map {
                (index: $0.zeroBasedEpubIndex, title: $0.displayTitle)
            } ?? []
        listeningRecovery.begin { [weak self] choice in
            guard let self, currentBook?.id == book.id else { return }
            startListening(presentsFullPlayer: presentsFullPlayer, requestedChapter: priority, requestedRatio: pageRatio,
                recovery: choice, optionsOverride: optionsOverride, voiceChange: voiceChange, pdfAnchor: pdfAnchor)
        }
        var options = optionsOverride ?? NarrationConversionOptions.current(for: settings.ttsPreferences)
        if let recovery { options = options.recovering(with: recovery.candidate, language: recovery.language) }
        listeningSession.start(book: book, priority: priority, pageRatio: pageRatio,
                               catalog: catalog, conversionOptions: options,
                               presentsFullPlayer: presentsFullPlayer,
                               chapterEstimates: readerController?.playbackChapterEstimates
                                   ?? ChapterPlaybackTimeline.estimates(for:
                                       LocalFulltextCache.inMemoryPayload(bookId: book.id)?.chapters ?? []),
                               voiceChange: voiceChange, pdfAnchor: pdfAnchor)
    }
}
#endif
