#if os(iOS)
import Combine
import UIKit

@MainActor
final class AdaptiveMaterialView: UIVisualEffectView {
    init() {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            super.init(effect: UIGlassEffect(style: .regular))
        } else {
            super.init(effect: UIBlurEffect(style: .systemMaterial))
        }
#else
        super.init(effect: UIBlurEffect(style: .systemMaterial))
#endif
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

enum ReaderChromeTransitionMetrics {
    static let duration: TimeInterval = 0.28
    static let animationOptions: UIView.AnimationOptions = [
        .curveEaseInOut,
        .beginFromCurrentState,
        .allowUserInteraction,
    ]
}

enum IOSReaderCoverArtSyncPolicy {
    static func shouldPublishNowPlayingCover(
        hasSnapshot: Bool,
        isConverting: Bool,
        hasLoadedAudioQueue: Bool
    ) -> Bool {
        hasSnapshot || isConverting || hasLoadedAudioQueue
    }
}

/// Temporary, opt-in stage capture for real-app relaunch profiling. It keeps
/// only stage names and monotonic timestamps, then emits one line at readiness.
final class IOSReaderOpenStageProfiler: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [(String, UInt64)] = []
    private var isRecording = false

    func begin(_ name: String, at timestamp: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if !isRecording {
            stages.removeAll(keepingCapacity: true)
            isRecording = true
        }
        stages.append((name, timestamp))
    }

    func record(_ name: String, at timestamp: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if name == "reader_open_requested", !isRecording {
            stages.removeAll(keepingCapacity: true)
            isRecording = true
        }
        guard isRecording else { return nil }
        stages.append((name, timestamp))
        guard name == "controls_usable" else { return nil }
        isRecording = false
        let origin = stages.first?.1 ?? timestamp
        return stages.map { name, time in
            "\(name)=\(Double(time - origin) / 1_000_000)ms"
        }.joined(separator: ",")
    }

    func observer() -> @Sendable (String, UInt64) -> Void {
        { [weak self] name, timestamp in
            guard let self, let summary = self.record(name, at: timestamp) else { return }
            NSLog("[APP21-reader-stages] %@", summary)
        }
    }
}

@MainActor
final class IOSRootContainerController: UIViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore
    private let readerOpenStageProfiler: IOSReaderOpenStageProfiler?

    private let shellController: IOSAppShellController
    private let readerController: MainReaderScreenController
    private let miniPlayerController: MiniPlayerContainerController
    private var fullPlayerController: FullPlayerScreenController?

    private var cancellables: Set<AnyCancellable> = []
    private var presentedErrorMessage: String?
    private var miniBottomToRoot: NSLayoutConstraint!
    private var miniBottomToTabBar: NSLayoutConstraint!
    private var miniPlayerMaximumHeight: NSLayoutConstraint!
    private let readerPresentationCoordinator = ReaderRootPresentationCoordinator()
    private var overlayStateInitialized = false
    private var miniPlayerVisibilityGeneration: UInt64 = 0
    private var isCommittingInitialReaderPresentation = false

    override var prefersStatusBarHidden: Bool {
        Self.shouldHideStatusBar(immersiveReaderMode: readerPresentationCoordinator.state.isChromeHidden)
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    static func shouldHideStatusBar(immersiveReaderMode _: Bool) -> Bool {
        // Fullscreen reader mode hides app chrome, not system safe-area
        // protection. Keeping the status bar visible gives the child reader
        // a stable top safe area and prevents text from being clipped under
        // the notch during chrome transitions.
        false
    }

    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore
    ) {
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            ReaderSessionState.setCurrentlyReading(bookID: nil)
        }
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        let profiler = ProcessInfo.processInfo.arguments.contains("-app21TimingProfile")
            ? IOSReaderOpenStageProfiler() : nil
        self.readerOpenStageProfiler = profiler
        self.shellController = IOSAppShellController(
            settings: settings,
            library: library,
            player: player,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore
        )
        self.readerController = MainReaderScreenController(
            library: library,
            settings: settings,
            player: player,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore,
            onBrowseLibrary: {
                ReaderSessionState.setCurrentlyReading(bookID: nil)
            },
            openStageObserver: profiler?.observer()
        )
        self.miniPlayerController = MiniPlayerContainerController(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: {
                playerPresentation.showFullPlayer()
            }
        )
        super.init(nibName: nil, bundle: nil)
        readerController.update(
            library: library,
            settings: settings,
            onBrowseLibrary: { [weak self] in
                self?.dismissReaderToLibrary()
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        recordStartupStage("root_view_did_load_started")
        view.backgroundColor = .systemBackground
        hydrateCachedChapterTitles()
        recordStartupStage("root_chapter_titles_hydrated")
        restoreLocalPlaybackControls()
        recordStartupStage("root_playback_controls_restored")
        let openingBookIDs = Set([
            UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
            UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey),
        ].compactMap { $0 })
        LocalFulltextCache.startPrewarmingRecentBooks(excludingBookIDs: openingBookIDs)
        recordStartupStage("root_prewarm_scheduled")
        recordStartupStage("root_shell_embed_started")
        embed(shellController)
        recordStartupStage("root_shell_embedded")
        recordStartupStage("root_reader_embed_started")
        embed(readerController)
        recordStartupStage("root_reader_embedded")
        embed(miniPlayerController)
        recordStartupStage("root_mini_player_embedded")

        shellController.view.translatesAutoresizingMaskIntoConstraints = false
        readerController.view.translatesAutoresizingMaskIntoConstraints = false
        miniPlayerController.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            shellController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shellController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shellController.view.topAnchor.constraint(equalTo: view.topAnchor),
            shellController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            readerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerController.view.topAnchor.constraint(equalTo: view.topAnchor),

        miniPlayerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        miniPlayerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),

        ])
        recordStartupStage("root_constraints_activated")

        miniBottomToRoot = miniPlayerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        miniBottomToTabBar = miniPlayerController.view.bottomAnchor.constraint(equalTo: shellController.tabBar.topAnchor, constant: -8)
        miniPlayerMaximumHeight = miniPlayerController.view.heightAnchor.constraint(
            lessThanOrEqualToConstant: MiniPlayerLayoutMetrics.maximumOverlayHeight
        )
        setMiniPlayerBottomAnchor(readerActive: true)
        miniPlayerMaximumHeight.isActive = true

        let readerBottomToMiniPlayer = readerController.view.bottomAnchor.constraint(equalTo: miniPlayerController.view.topAnchor)
        let readerBottomToRoot = readerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        readerBottomToMiniPlayer.isActive = true
        readerPresentationCoordinator.configureChromeLayout(
            rootView: view,
            readerBottomToMiniPlayer: readerBottomToMiniPlayer,
            readerBottomToRoot: readerBottomToRoot
        )
        readerController.onReaderChromeVisibilityChanged = { [weak self] isHidden in
            self?.setImmersiveReaderMode(isHidden)
        }
        readerController.onReaderLoadingChanged = { [weak self] isLoading in
            self?.setReaderLoadingMode(isLoading)
        }
        // Embedding the reader can synchronously start its book load before
        // the root's callbacks exist. Synchronize after every constraint is
        // installed so the initial loading cover owns the whole reader area.
        _ = readerPresentationCoordinator.setLoading(readerController.isLoadingBookContent)
        recordStartupStage("root_reader_callbacks_installed")

        miniPlayerController.view.backgroundColor = .clear
        shellController.configureMiniPlayerAccessory(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: { [weak self] in
                self?.showFullPlayer()
            },
            onPlayRequested: { [weak self] in
                self?.readerController.startListeningFromMiniPlayer()
            }
        )

        bindState()
        recordStartupStage("root_state_bound")
        updateTheme(settings.readerTheme)
        recordStartupStage("root_theme_updated")
        isCommittingInitialReaderPresentation = true
        refreshOverlayState()
        isCommittingInitialReaderPresentation = false
        recordStartupStage("root_view_did_load_completed")
    }

    private func recordStartupStage(_ name: String) {
        guard let readerOpenStageProfiler else { return }
        let timestamp = DispatchTime.now().uptimeNanoseconds
        if name == "root_view_did_load_started" {
            readerOpenStageProfiler.begin(name, at: timestamp)
        } else if let summary = readerOpenStageProfiler.record(name, at: timestamp) {
            NSLog("[APP21-reader-stages] %@", summary)
        }
    }

    private func setImmersiveReaderMode(_ isHidden: Bool) {
        guard let token = readerPresentationCoordinator.beginChromeTransition(
            to: isHidden,
            captureViewport: { [weak self] in self?.readerController.captureReaderViewportTransition() }
        ) else { return }
        setNeedsStatusBarAppearanceUpdate()
        refreshOverlayState(viewportTransition: token)
    }

    private func setReaderLoadingMode(_ isLoading: Bool) {
        guard readerPresentationCoordinator.setLoading(isLoading) else { return }
        setNeedsStatusBarAppearanceUpdate()
        refreshOverlayState()
    }

    private func refreshMiniPlayerContent() {
        recordStartupStage("root_mini_refresh_started")
        syncPlayerCoverArt()
        recordStartupStage("root_now_playing_cover_synced")
        miniPlayerController.update(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: { [weak self] in
                self?.showFullPlayer()
            },
            onPlayRequested: { [weak self] in
                self?.readerController.startListeningFromMiniPlayer()
            }
        )
        recordStartupStage("root_mini_player_updated")
        shellController.refreshMiniPlayerAccessory(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: { [weak self] in
                self?.showFullPlayer()
            },
            onPlayRequested: { [weak self] in
                self?.readerController.startListeningFromMiniPlayer()
            }
        )
        recordStartupStage("root_shell_mini_player_updated")
    }

    private func syncPlayerCoverArt() {
        guard IOSReaderCoverArtSyncPolicy.shouldPublishNowPlayingCover(
            hasSnapshot: player.snapshot != nil,
            isConverting: player.isConverting,
            hasLoadedAudioQueue: player.hasLoadedAudioQueue
        ) else { return }
        syncPlayerCoverArtNow()
    }

    private func syncPlayerCoverArtNow() {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let cover = bookID.flatMap { id in library.books.first(where: { $0.id == id })?.coverPNG }
        player.updateCoverArtData(cover)
    }

    private func applyReaderChromeLayout(
        viewportTransition: ReaderViewportTransition.Token? = nil,
        needsFinalLayout: Bool = false
    ) {
        recordStartupStage("root_chrome_layout_started")
        readerPresentationCoordinator.applyChromeLayout(
            transition: viewportTransition,
            needsFinalLayout: needsFinalLayout,
            deferInitialLayout: isCommittingInitialReaderPresentation,
            restoreViewport: { [weak self] in self?.readerController.completeReaderChromeLayoutTransition() }
        )
        recordStartupStage("root_chrome_layout_completed")
    }

    private func showFullPlayer() {
        ensureFullPlayerController()
        playerPresentation.showFullPlayer()
        refreshOverlayState()
    }

    private func ensureFullPlayerController() {
        guard fullPlayerController == nil, isViewLoaded else { return }
        let controller = FullPlayerScreenController(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            playerPresentation: playerPresentation,
            settings: settings
        )
        fullPlayerController = controller
        embed(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        controller.view.backgroundColor = .clear
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    func updateTheme(_ theme: ReaderTheme) {
        let colors = settings.readerColors
        view.backgroundColor = colors.background
        miniPlayerController.applyReaderBackground(colors.background)
        shellController.applyTheme(theme, preferredColorScheme: settings.readerPreferredColorScheme)
        readerController.update(
            library: library,
            settings: settings,
            onBrowseLibrary: { [weak self] in self?.dismissReaderToLibrary() }
        )
        refreshMiniPlayerContent()
        fullPlayerController?.refresh(library: library)
        switch settings.readerPreferredColorScheme {
        case .dark:
            overrideUserInterfaceStyle = .dark
        case .light:
            overrideUserInterfaceStyle = .light
        case nil:
            overrideUserInterfaceStyle = .unspecified
        }
    }

    /// A full player may be restored before the reader controller is shown.
    /// Restore its TOC titles from the local parsed-book cache so every
    /// playback surface has canonical metadata immediately after launch.
    private func hydrateCachedChapterTitles() {
        let activeReaderBookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let bookID = activeReaderBookID
            ?? UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        // The active reader hydrates this same catalog after its prepared
        // chapter is visible. Decoding it here would compete with that read.
        guard let bookID, bookID != activeReaderBookID else { return }
        Task { [weak self] in
            let fulltext = await Task.detached(priority: .utility) {
                LocalFulltextCache.read(bookId: bookID)
            }.value
            guard let fulltext else { return }
            self?.player.updateReaderChapterTitles(fulltext.chapters)
        }
    }

    /// Rebuilds a paused local queue from the durable artifact manifest. This
    /// makes the mini player, expanded player, widget and lock-screen controls
    /// useful immediately after a relaunch without restarting conversion or
    /// claiming the user's audio session.
    private func restoreLocalPlaybackControls() {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        guard let bookID else { return }
        let epubChapterIndex = UserDefaults.standard.object(
            forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey
        ) as? Int ?? 0
        Task { [weak self] in
            guard let self else { return }
            let embeddedSnapshot = try? await LocalAudioArtifactStore.shared.playableSnapshot(
                bookID: bookID,
                engine: settings.audioEngine.rawValue,
                voice: "auto",
                language: nil
            )
            let conversionJobID = library.books.first(where: { $0.id == bookID })?.lastJobId
            let restoredSnapshot: JobSnapshot?
            if let conversionJobID {
                restoredSnapshot = await Task.detached(priority: .utility) {
                    let converted = RustConversionCoordinator.persistedSnapshot(jobID: conversionJobID)
                    return DownloadManager.restoredPlaybackSnapshot(jobId: conversionJobID,
                                                                   conversionSnapshot: converted)
                }.value
            } else {
                restoredSnapshot = nil
            }
            guard let snapshot = embeddedSnapshot ?? restoredSnapshot else {
                return
            }
            let queueOffset = AudioPlayer.restoredPlayableChapterOffset(
                snapshot: snapshot,
                persistedEpubChapterIndex: epubChapterIndex
            )
            player.play(
                snapshot: snapshot,
                startingAt: queueOffset,
                restoreAutoplay: false
            )
            refreshOverlayState()
        }
    }

    func refreshOverlayState(
        viewportTransition: ReaderViewportTransition.Token? = nil
    ) {
        recordStartupStage("root_overlay_refresh_started")
        refreshMiniPlayerContent()
        recordStartupStage("root_overlay_mini_content_updated")
        let currentBookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let currentlyReadingBookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let availableBookIDs = Set(library.books.map(\.id))
        let readerActive = currentlyReadingBookID.flatMap { id in availableBookIDs.contains(id) ? id : nil } != nil
        let showMini = IOSMiniPlayerPolicy.shouldShow(
            currentBookID: currentBookID,
            currentlyReadingBookID: currentlyReadingBookID,
            availableBookIDs: availableBookIDs
        )

        let wasImmersive = readerPresentationCoordinator.state.isChromeHidden
        readerPresentationCoordinator.setReaderActive(readerActive)
        readerController.view.isHidden = !readerActive
        // The reader owns the full screen while open. The library/settings/
        // conversion tabs must not remain visible underneath its player bar.
        if readerActive {
            shellController.setSystemMiniPlayerVisible(false, animated: false)
        }
        shellController.setReaderTabBarHidden(
            readerActive,
            animated: !isCommittingInitialReaderPresentation
        )
        setMiniPlayerBottomAnchor(readerActive: readerActive)
        if !readerActive {
            if wasImmersive {
                setNeedsStatusBarAppearanceUpdate()
            }
        }
        let needsFinalReaderLayout = readerController.applyReaderPresentation(readerPresentationCoordinator.state)
        recordStartupStage("root_reader_presentation_applied")
        applyReaderChromeLayout(
            viewportTransition: viewportTransition,
            needsFinalLayout: needsFinalReaderLayout
        )
        let miniShouldBeVisible = readerActive
            ? readerPresentationCoordinator.state.showsMiniPlayer(bookHasPlayback: showMini)
            : showMini
        if shellController.supportsSystemBottomAccessory, !readerActive {
            shellController.setSystemMiniPlayerVisible(miniShouldBeVisible, animated: true)
            hideOverlayMiniPlayerImmediately()
        } else {
            shellController.setSystemMiniPlayerVisible(false, animated: false)
            animateMiniPlayerVisibility(
                visible: miniShouldBeVisible,
                animated: !isCommittingInitialReaderPresentation
            )
        }
        if playerPresentation.showingFullPlayer {
            ensureFullPlayerController()
        }
        fullPlayerController?.view.isHidden = !playerPresentation.showingFullPlayer
        fullPlayerController?.view.alpha = playerPresentation.showingFullPlayer ? 1 : 0
        recordStartupStage("root_overlay_visibility_updated")
        presentPlayerErrorIfNeeded()
        recordStartupStage("root_overlay_refresh_completed")
    }

    private func animateMiniPlayerVisibility(visible: Bool, animated: Bool = true) {
        miniPlayerVisibilityGeneration &+= 1
        let generation = miniPlayerVisibilityGeneration
        let wasVisible = overlayStateInitialized && !miniPlayerController.view.isHidden
            && miniPlayerController.view.alpha > 0.01
        let changed = !overlayStateInitialized || wasVisible != visible
        overlayStateInitialized = true
        guard changed else { return }

        if visible {
            miniPlayerController.view.isHidden = false
            miniPlayerController.view.alpha = animated ? 0 : 1
        }

        let animations = {
            self.miniPlayerController.view.alpha = visible ? 1 : 0
        }
        let completion: (Bool) -> Void = { _ in
            guard generation == self.miniPlayerVisibilityGeneration else { return }
            if !visible {
                self.miniPlayerController.view.isHidden = true
            }
        }

        if animated {
            UIView.animate(
                withDuration: ReaderChromeTransitionMetrics.duration,
                delay: 0,
                options: ReaderChromeTransitionMetrics.animationOptions,
                animations: animations,
                completion: completion
            )
        } else {
            animations()
            completion(true)
        }
    }

    /// The overlay has exactly one vertical owner. Keeping both anchors active
    /// during a tab-bar transition collapses the mini player to the tab bar's
    /// height and forces UIKit to break its content constraints.
    private func setMiniPlayerBottomAnchor(readerActive: Bool) {
        NSLayoutConstraint.deactivate([miniBottomToRoot, miniBottomToTabBar])
        (readerActive ? miniBottomToRoot : miniBottomToTabBar).isActive = true
    }

    private func hideOverlayMiniPlayerImmediately() {
        miniPlayerController.view.layer.removeAllAnimations()
        miniPlayerController.view.alpha = 0
        miniPlayerController.view.isHidden = true
        overlayStateInitialized = true
    }

    private func dismissReaderToLibrary() {
        ReaderSessionState.setCurrentlyReading(bookID: nil)
        refreshOverlayState()
    }

    private func bindState() {
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateTheme(self.settings.readerTheme)
            }
            .store(in: &cancellables)
        playerPresentation.$showingFullPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
        library.objectWillChange
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
        player.objectWillChange
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
        // `UserDefaults.didChangeNotification` is posted synchronously on
        // whatever thread called `UserDefaults.set` — including the
        // background `persistenceQueue` used by `LibraryStore.persist()`
        // (moved off main to avoid blocking the UI on JSON encode). Without
        // `.receive(on: .main)` here, `refreshOverlayState()` — MainActor
        // isolated via this controller — runs off the main executor and
        // Swift's runtime isolation check crashes with
        // `dispatch_assert_queue_fail` the moment a book is added/removed.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    private func presentPlayerErrorIfNeeded() {
        guard let error = player.lastError?.errorDescription, error != presentedErrorMessage else { return }
        presentedErrorMessage = error
        let alert = UIAlertController(
            title: L10n.string("player.error.title"),
            message: error,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default) { [weak self] _ in
            self?.player.lastError = nil
            self?.presentedErrorMessage = nil
        })
        if presentedViewController == nil {
            present(alert, animated: true)
        }
    }
}

@MainActor
private final class MiniPlayerContainerController: UIViewController {
    private let miniPlayerView = MiniPlayerBarUIKitView()

    init(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void
    ) {
        super.init(nibName: nil, bundle: nil)
        miniPlayerView.configure(
            player: player,
            playbackClock: playbackClock,
            library: library,
            onTap: onTap
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = miniPlayerView
        view.accessibilityIdentifier = "miniPlayer.container"
    }

    func update(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void,
        onPlayRequested: @escaping () -> Void
    ) {
        miniPlayerView.configure(
            player: player,
            playbackClock: playbackClock,
            library: library,
            onTap: onTap,
            onPlayRequested: onPlayRequested
        )
    }

    func applyReaderBackground(_ color: UIColor) {
        miniPlayerView.applyReaderBackground(color)
    }
}
#endif
