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
    private let conversionExecutor: RustConversionCoordinator.Executor
    private var listeningJobID: String?
    private var listeningBookID: String?
    private var listeningChapters: [JobSnapshot.Chapter] = []
    private var hasDeliveredListeningChapter = false
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
        conversionExecutor: @escaping RustConversionCoordinator.Executor = RustConversionCoordinator.execute,
        sessionDefaults: UserDefaults = .standard
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        self.onBrowseLibrary = onBrowseLibrary
        self.conversionExecutor = conversionExecutor
        self.sessionDefaults = sessionDefaults
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

        // Backend jobs are cancelled through the API job lifecycle.
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
        guard let book = currentBook, book.fileType.supportsAudioConversion else { return }
        guard !isLoadingBookContent else { return }
        guard readerController == nil || readerBookID == book.id else { return }
        guard listeningJobID == nil || listeningBookID != book.id else { return }
        let priority = readerController?.currentReaderChapterIndex
            ?? ReaderPlaybackPriorityChapter.index(bookID: book.id, defaults: sessionDefaults)
        guard let chapterStart = Int32(exactly: priority), chapterStart >= 0 else { return }
        let jobID = UUID().uuidString
        let previousPlayerJob = player.snapshot?.jobId
        listeningJobID = jobID
        listeningBookID = book.id
        listeningChapters = []
        hasDeliveredListeningChapter = false
        Task { [weak self] in
            guard let self else { return }
            var installedPending = false
            defer {
                if self.listeningJobID == jobID {
                    self.listeningJobID = nil
                    self.listeningBookID = nil
                }
            }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                guard listeningJobID == jobID, currentBook?.id == book.id,
                      player.snapshot?.jobId == previousPlayerJob else { return }
                let pending = JobSnapshot(jobId: jobID, state: "running", bookTitle: book.resolvedTitle,
                    bookAuthor: book.author, coverUrl: nil, coverMimeType: nil, engine: nil,
                    voice: nil, language: nil, progressPercent: 0, chaptersTotal: nil,
                    chaptersCompleted: 0, chapterProgress: [], outputs: nil, logUrl: nil,
                    error: nil, lastActivityAt: Date().timeIntervalSince1970)
                if player.positionSeconds > 1 {
                    player.pause()
                    player.persistResumePoint(force: true)
                }
                player.stop()
                player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
                installedPending = true
                player.isConverting = true
                player.resume()
                let result = try await conversionExecutor(url, jobID, chapterStart, -1, nil,
                    { [weak self] event in
                        guard let self, self.listeningJobID == jobID,
                              self.player.snapshot?.jobId == jobID, event.jobId == jobID,
                              event.chapterIndex >= priority, event.audioPath.isFileURL,
                              FileManager.default.isReadableFile(atPath: event.audioPath.path) else { return }
                        guard self.hasDeliveredListeningChapter || self.currentBook?.id == book.id else {
                            self.player.pause()
                            return
                        }
                        let chapter = event.playableChapter
                        if let index = self.listeningChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.listeningChapters[index] = chapter
                        } else { self.listeningChapters.append(chapter) }
                        self.listeningChapters.sort { $0.index < $1.index }
                        guard self.listeningChapters.contains(where: { $0.index == priority }) else { return }
                        self.player.updateSnapshot(event.snapshot(chapters: self.listeningChapters))
                        if !self.hasDeliveredListeningChapter {
                            self.hasDeliveredListeningChapter = true
                            if presentsFullPlayer { self.playerPresentation.showFullPlayer() }
                        }
                    })
                let snapshot = try result.snapshot()
                guard result.jobID == jobID, snapshot.jobId == jobID else {
                    throw EmbeddedConverterError.conversionFailed("Conversion returned a different listening job.")
                }
                let indices = snapshot.playableChapters.map(\.index)
                guard indices.first == priority, indices == indices.sorted(), Set(indices).count == indices.count else {
                    throw EmbeddedConverterError.conversionFailed("Conversion did not preserve the requested chapter order.")
                }
                self.library.recordConversion(jobId: result.jobID, for: book.id)
                guard listeningJobID == jobID, player.snapshot?.jobId == jobID else { return }
                if !hasDeliveredListeningChapter, currentBook?.id != book.id {
                    player.pause()
                }
                player.finishStreaming(snapshot: snapshot)
            } catch let error as StoragePressureError {
                guard listeningJobID == jobID else { return }
                guard player.snapshot?.jobId == (installedPending ? jobID : previousPlayerJob) else { return }
                concludeFailedListening(error, jobID: jobID)
                guard currentBook?.id == book.id else { return }
                self.presentStorageManagementAlert(error)
            } catch {
                guard listeningJobID == jobID else { return }
                guard player.snapshot?.jobId == (installedPending ? jobID : previousPlayerJob) else { return }
                concludeFailedListening(error, jobID: jobID)
                guard currentBook?.id == book.id else { return }
                let alert = UIAlertController(
                    title: L10n.string("bookDetail.listenStart"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func concludeFailedListening(_ error: Error, jobID: String) {
        guard let current = player.snapshot, current.jobId == jobID else { return }
        if !hasDeliveredListeningChapter { player.pause() }
        let failed = JobSnapshot(jobId: current.jobId, state: "failed", bookTitle: current.bookTitle,
            bookAuthor: current.bookAuthor, coverUrl: current.coverUrl, coverMimeType: current.coverMimeType,
            engine: current.engine, voice: current.voice, language: current.language,
            progressPercent: current.progressPercent, chaptersTotal: current.chaptersTotal,
            chaptersCompleted: current.chaptersCompleted, chapterProgress: current.chapterProgress,
            outputs: current.outputs, logUrl: current.logUrl, error: error.localizedDescription,
            lastActivityAt: Date().timeIntervalSince1970)
        player.finishStreaming(snapshot: failed)
    }

    private func presentStorageManagementAlert(_ error: StoragePressureError) {
        let alert = UIAlertController(
            title: L10n.string("settings.insufficientStorageTitle"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: L10n.string("settings.manageDownloads"),
            style: .default
        ) { [weak self] _ in
            guard let self else { return }
            let controller = LocalAudioDownloadsScreenController(library: self.library)
            self.present(UINavigationController(rootViewController: controller), animated: true)
        })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        present(alert, animated: true)
    }
}

private enum ReaderNavigationLayoutMetrics {
    /// Keeps glyphs and selection handles clear of iOS's floating navigation
    /// controls while preserving the bar's intrinsic platform height.
    static let initialBarHeight: CGFloat = 44
    static let readerContentTopSpacing: CGFloat = 12
}
#endif
