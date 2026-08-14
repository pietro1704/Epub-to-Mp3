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
    private var onBrowseLibrary: (() -> Void)?
    var onReaderChromeVisibilityChanged: ((Bool) -> Void)?
    var onReaderLoadingChanged: ((Bool) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var readerController: BookOpenScreenController?
    private var readerBookID: String?
    private var readerNavigationHeight: NSLayoutConstraint!
    private var readerTopToNavigation: NSLayoutConstraint!
    private var readerTopToRoot: NSLayoutConstraint!
    /// Loading is a reader-content fact, not duplicated presentation state.
    var isLoadingBookContent: Bool { readerController?.isLoadingBookContent ?? false }

    private let emptyStateStack = UIStackView()
    private let emptyTitleLabel = UILabel()
    private let emptyDescriptionLabel = UILabel()
    private let browseButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)
    private let readerNavigationBackground = AdaptiveMaterialView()
    private let readerNavigationBar = UINavigationBar()
    private let readerNavigationItem = UINavigationItem()

    private var currentBook: BookEntity? {
        guard let id = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              !id.isEmpty else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    init(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore,
        onBrowseLibrary: (() -> Void)?
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        self.onBrowseLibrary = onBrowseLibrary
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureReaderNavigationBar()
        configureEmptyState()
        configureListenButton()
        bind()
        render()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateReaderNavigationHeightIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    func update(
        library: LibraryStore,
        settings: AppSettings,
        onBrowseLibrary: (() -> Void)?
    ) {
        self.library = library
        self.settings = settings
        self.onBrowseLibrary = onBrowseLibrary
        render()
    }

    private func bind() {
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

    private func configureEmptyState() {
        emptyStateStack.axis = .vertical
        emptyStateStack.spacing = 20
        emptyStateStack.alignment = .center
        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false

        emptyTitleLabel.font = .preferredFont(forTextStyle: .title2)
        emptyTitleLabel.numberOfLines = 0
        emptyTitleLabel.textAlignment = .center
        emptyTitleLabel.text = L10n.string("mainReader.pickBook")

        emptyDescriptionLabel.font = .preferredFont(forTextStyle: .body)
        emptyDescriptionLabel.textColor = .secondaryLabel
        emptyDescriptionLabel.numberOfLines = 0
        emptyDescriptionLabel.textAlignment = .center
        emptyDescriptionLabel.text = L10n.string("mainReader.pickBookDescription")

        var browseConfig = UIButton.Configuration.filled()
        browseConfig.image = UIImage(systemName: "books.vertical")
        browseConfig.imagePadding = 8
        browseConfig.title = L10n.string("mainReader.browseLibrary")
        browseButton.configuration = browseConfig
        browseButton.addTarget(self, action: #selector(browseLibraryTapped), for: .touchUpInside)
        browseButton.accessibilityIdentifier = "mainReader.browseLibrary"

        [emptyTitleLabel, emptyDescriptionLabel, browseButton].forEach { emptyStateStack.addArrangedSubview($0) }
        view.addSubview(emptyStateStack)
        NSLayoutConstraint.activate([
            emptyStateStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            emptyStateStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

    }

    private func configureListenButton() {
        // Playback is controlled exclusively from the persistent mini-player.
        // A second "Listen" button here duplicated the control and pushed the
        // reader content into an inconsistent layout while a book was loading.
        listenButton.isHidden = true
        listenButton.translatesAutoresizingMaskIntoConstraints = false
        listenButton.accessibilityIdentifier = "mainReader.listen"
        listenButton.addTarget(self, action: #selector(listenTapped), for: .touchUpInside)
    }

    private func configureReaderNavigationBar() {
        readerNavigationBar.translatesAutoresizingMaskIntoConstraints = false
        readerNavigationBackground.translatesAutoresizingMaskIntoConstraints = false
        readerNavigationBar.accessibilityIdentifier = "reader.navigationBar"
        readerNavigationBar.setContentHuggingPriority(.required, for: .vertical)
        readerNavigationBar.setContentCompressionResistancePriority(.required, for: .vertical)
        readerNavigationBar.isTranslucent = true
        readerNavigationBar.prefersLargeTitles = false
        readerNavigationBar.items = [readerNavigationItem]
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.shadowColor = .clear
        readerNavigationBar.standardAppearance = appearance
        readerNavigationBar.scrollEdgeAppearance = appearance
        readerNavigationBar.compactAppearance = appearance

        let closeItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(closeReaderTapped)
        )
        closeItem.accessibilityLabel = L10n.string("common.back")
        closeItem.accessibilityIdentifier = "reader.close"
        readerNavigationItem.leftBarButtonItem = closeItem

        readerNavigationItem.rightBarButtonItem = nil

        // A standalone UINavigationBar starts below the sensor area. Its
        // material continues to the screen edge so the bar remains attached
        // to the top while its controls still respect the safe area.
        view.addSubview(readerNavigationBackground)
        view.addSubview(readerNavigationBar)
        NSLayoutConstraint.activate([
            readerNavigationBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerNavigationBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerNavigationBackground.topAnchor.constraint(equalTo: view.topAnchor),
            readerNavigationBackground.bottomAnchor.constraint(equalTo: readerNavigationBar.bottomAnchor),
            readerNavigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerNavigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerNavigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        readerNavigationHeight = readerNavigationBar.heightAnchor.constraint(
            equalToConstant: ReaderNavigationLayoutMetrics.initialBarHeight
        )
        readerNavigationHeight.isActive = true
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
        listenButton.isHidden = currentBook == nil || isLoadingBookContent
    }

    private func updateReaderNavigationHeightIfNeeded() {
        guard view.bounds.width > 0 else { return }
        let fittedHeight = readerNavigationBar.sizeThatFits(
            CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        guard fittedHeight > 0,
              abs(readerNavigationHeight.constant - fittedHeight) > .ulpOfOne else {
            return
        }
        readerNavigationHeight.constant = fittedHeight
    }

    private func showEmptyState() {
        removeReaderControllerIfNeeded()
        emptyStateStack.isHidden = false
        listenButton.isHidden = true
        readerNavigationBar.isHidden = true
        readerNavigationBackground.isHidden = true
    }

    private func showBook(_ book: BookEntity) {
        emptyStateStack.isHidden = true
        readerNavigationItem.title = book.resolvedTitle
        if readerController != nil, readerBookID == book.id {
            // The existing reader already owns this book. Re-loading it on
            // every library notification causes `loadBook()` to publish a
            // loading-state change, which re-enters `render()` indefinitely.
            return
        }
        replaceActivePlaybackIfNeeded(for: book)
        // Reset immersive chrome only when creating/opening a different
        // reader. Playback/title updates during pagination re-enter render()
        // but must not make the hidden mini player visible again.
        onReaderChromeVisibilityChanged?(false)
        readerNavigationBar.isHidden = false
        readerNavigationBar.alpha = 1
        readerNavigationBackground.isHidden = false
        readerNavigationBackground.alpha = 1

        removeReaderControllerIfNeeded()

        let reader = BookOpenScreenController(
            book: book,
            library: library,
            settings: settings,
            bookmarkStore: bookmarkStore,
            player: player
        )
        reader.onLoadStateChanged = { [weak self] isLoading in
            guard let self else { return }
            self.listenButton.isHidden = self.currentBook == nil || isLoading
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
            equalTo: readerNavigationBar.bottomAnchor,
            constant: ReaderNavigationLayoutMetrics.readerContentTopSpacing
        )
        readerTopToRoot = reader.view.topAnchor.constraint(equalTo: view.topAnchor)
        NSLayoutConstraint.activate([
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerTopToNavigation,
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reader.didMove(toParent: self)
        view.bringSubviewToFront(readerNavigationBackground)
        view.bringSubviewToFront(readerNavigationBar)
        readerController = reader
        readerBookID = book.id
        readerNavigationItem.rightBarButtonItems = reader.navigationBarButtonItems
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
        let activeBookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let hasActivePlayback = player.snapshot != nil || player.hasLoadedAudioQueue || player.isConverting
        guard Self.shouldReplaceActivePlayback(
            activeBookID: activeBookID,
            incomingBookID: book.id,
            hasActivePlayback: hasActivePlayback
        ) else {
            return
        }

        EmbeddedConversionCoordinator.cancelActiveStream()
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
        applyReaderNavigationLayout(
            shouldShow: state.showsReaderNavigation,
            animated: false,
            commitsLayout: false
        )
        return chromeChanged || navigationChanged
    }

    private func applyReaderNavigationLayout(
        shouldShow: Bool,
        animated: Bool,
        commitsLayout: Bool = true
    ) {
        if let readerTopToNavigation,
           let readerTopToRoot {
            NSLayoutConstraint.deactivate([readerTopToNavigation, readerTopToRoot])
            (shouldShow ? readerTopToNavigation : readerTopToRoot).isActive = true
        }

        if shouldShow {
            readerNavigationBar.isHidden = false
            readerNavigationBackground.isHidden = false
            if animated { readerNavigationBar.alpha = 0 }
            if animated { readerNavigationBackground.alpha = 0 }
        } else if !animated {
            readerNavigationBar.alpha = 0
            readerNavigationBar.isHidden = true
            readerNavigationBackground.alpha = 0
            readerNavigationBackground.isHidden = true
        }

        let changes = {
            self.readerNavigationBar.alpha = shouldShow ? 1 : 0
            self.readerNavigationBackground.alpha = shouldShow ? 1 : 0
            self.view.layoutIfNeeded()
        }
        guard animated else {
            if commitsLayout {
                changes()
            }
            return
        }
        UIView.animate(
            withDuration: ReaderChromeTransitionMetrics.duration,
            delay: 0,
            options: ReaderChromeTransitionMetrics.animationOptions,
            animations: changes
        ) { [weak self] _ in
            guard let self else { return }
            guard !shouldShow else { return }
            self.readerNavigationBar.isHidden = true
            self.readerNavigationBackground.isHidden = true
        }
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
        readerNavigationItem.rightBarButtonItems = nil
    }

    private func autoClearMissingBookIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              !library.books.contains(where: { $0.id == id }) else { return }
        ReaderSessionState.setCurrentlyReading(bookID: nil)
    }

    @objc
    private func closeReaderTapped() {
        ReaderSessionState.setCurrentlyReading(bookID: nil)
        onBrowseLibrary?()
    }

    @objc
    private func repickBookTapped() {
        readerController?.presentDocumentPicker()
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

    private func startListening(presentsFullPlayer: Bool) {
        guard let book = currentBook else { return }
        if settings.useEmbeddedRuntime && !book.fileType.requiresServerConversion {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let priorityChapterIndex = self.readerController?.currentReaderChapterIndex
                        ?? ReaderProgressStore.read(bookId: book.id)?.chapterIndex
                        ?? 0
                    if let localSnapshot = await EmbeddedConversionCoordinator.resumeLocalPlaybackIfAvailable(
                        bookID: book.id,
                        priorityChapterIndices: [priorityChapterIndex],
                        player: self.player
                    ) {
                        if presentsFullPlayer {
                            self.playerPresentation.showFullPlayer()
                        }
                        if localSnapshot.state == "finished" {
                            self.library.recordConversion(jobId: localSnapshot.jobId, for: book.id)
                            return
                        }

                        let url = try await self.library.openBookFileAsync(id: book.id)
                        let snapshot = try await EmbeddedConversionCoordinator.continuePartialLocalPlayback(
                            bookURL: url,
                            bookID: book.id,
                            requiresWiFi: !self.settings.allowCellularAudioConversion,
                            priorityChapterIndices: [priorityChapterIndex],
                            player: self.player
                        )
                        self.library.recordConversion(jobId: snapshot.jobId, for: book.id)
                        return
                    }

                    let url = try await self.library.openBookFileAsync(id: book.id)
                    let snapshot = try await EmbeddedConversionCoordinator.stream(
                        bookURL: url,
                        bookID: book.id,
                        requiresWiFi: !self.settings.allowCellularAudioConversion,
                        priorityChapterIndices: [priorityChapterIndex],
                        player: self.player,
                        onStreamingStarted: { [weak self] in
                            if presentsFullPlayer {
                                self?.playerPresentation.showFullPlayer()
                            }
                        }
                    )
                    self.library.recordConversion(jobId: snapshot.jobId, for: book.id)
                } catch {
                    let alert = UIAlertController(
                        title: L10n.string("bookDetail.listenStart"),
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                    self.present(alert, animated: true)
                }
            }
            return
        }
        if let jobId = book.lastJobId {
            navigationController?.pushViewController(
                JobDetailScreenController(
                    jobId: jobId, settings: settings, library: library, player: player, playbackClock: player.playbackClock
                ),
                animated: true
            )
            return
        }
        guard let url = try? library.openBookFile(id: book.id) else { return }
        navigationController?.pushViewController(
            ConvertScreenController(
                settings: settings, library: library, player: player,
                playbackClock: player.playbackClock,
                preselectedFileURL: url,
                preselectedBookID: book.id
            ),
            animated: true
        )
    }
}

private enum ReaderNavigationLayoutMetrics {
    /// Keeps glyphs and selection handles clear of iOS's floating navigation
    /// controls while preserving the bar's intrinsic platform height.
    static let initialBarHeight: CGFloat = 44
    static let readerContentTopSpacing: CGFloat = 12
}
#endif
