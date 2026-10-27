#if os(iOS)
import Combine
import UIKit

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
    private var isCommittingInitialReaderPresentation = false
    private lazy var miniPlayerPresentation = IOSMiniPlayerPresentation(view: miniPlayerController.view)

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
        readerOpenStageProfiler?.recordStartupStage("root_view_did_load_started")
        view.backgroundColor = .systemBackground
        IOSReaderPlaybackPreparation.hydrateCachedChapterTitles(player: player, owner: self)
        readerOpenStageProfiler?.recordStartupStage("root_chapter_titles_hydrated")
        IOSReaderPlaybackPreparation.restoreLocalPlaybackControls(settings: settings, library: library, player: player, owner: self) { [weak self] in self?.refreshOverlayState() }
        readerOpenStageProfiler?.recordStartupStage("root_playback_controls_restored")
        let openingBookIDs = Set([
            UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
            UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey),
        ].compactMap { $0 })
        LocalFulltextCache.startPrewarmingRecentBooks(excludingBookIDs: openingBookIDs)
        readerOpenStageProfiler?.recordStartupStage("root_prewarm_scheduled")
        readerOpenStageProfiler?.recordStartupStage("root_shell_embed_started")
        embed(shellController)
        readerOpenStageProfiler?.recordStartupStage("root_shell_embedded")
        readerOpenStageProfiler?.recordStartupStage("root_reader_embed_started")
        embed(readerController)
        readerOpenStageProfiler?.recordStartupStage("root_reader_embedded")
        embed(miniPlayerController)
        readerOpenStageProfiler?.recordStartupStage("root_mini_player_embedded")

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
        readerOpenStageProfiler?.recordStartupStage("root_constraints_activated")

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
        readerOpenStageProfiler?.recordStartupStage("root_reader_callbacks_installed")

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
        readerOpenStageProfiler?.recordStartupStage("root_state_bound")
        updateTheme(settings.readerTheme)
        readerOpenStageProfiler?.recordStartupStage("root_theme_updated")
        isCommittingInitialReaderPresentation = true
        refreshOverlayState()
        isCommittingInitialReaderPresentation = false
        readerOpenStageProfiler?.recordStartupStage("root_view_did_load_completed")
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
        readerOpenStageProfiler?.recordStartupStage("root_mini_refresh_started")
        syncPlayerCoverArt()
        readerOpenStageProfiler?.recordStartupStage("root_now_playing_cover_synced")
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
        readerOpenStageProfiler?.recordStartupStage("root_mini_player_updated")
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
        readerOpenStageProfiler?.recordStartupStage("root_shell_mini_player_updated")
    }

    private func syncPlayerCoverArt() {
        guard IOSReaderCoverArtSyncPolicy.shouldPublishNowPlayingCover(
            hasSnapshot: player.snapshot != nil,
            isConverting: player.isConverting,
            hasLoadedAudioQueue: player.hasLoadedAudioQueue
        ) else { return }
        IOSReaderPlaybackPreparation.syncPlayerCoverArtNow(player: player, library: library)
    }

    private func applyReaderChromeLayout(
        viewportTransition: ReaderViewportTransition.Token? = nil,
        needsFinalLayout: Bool = false
    ) {
        readerOpenStageProfiler?.recordStartupStage("root_chrome_layout_started")
        readerPresentationCoordinator.applyChromeLayout(
            transition: viewportTransition,
            needsFinalLayout: needsFinalLayout,
            deferInitialLayout: isCommittingInitialReaderPresentation,
            restoreViewport: { [weak self] in self?.readerController.completeReaderChromeLayoutTransition() }
        )
        readerOpenStageProfiler?.recordStartupStage("root_chrome_layout_completed")
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
            settings: settings,
            onStartListening: { [weak self] in
                self?.readerController.startListeningFromMiniPlayer()
            }
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
        view.layoutIfNeeded()
        controller.setPresented(false, animated: false)
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
    func refreshOverlayState(
        viewportTransition: ReaderViewportTransition.Token? = nil
    ) {
        readerOpenStageProfiler?.recordStartupStage("root_overlay_refresh_started")
        refreshMiniPlayerContent()
        readerOpenStageProfiler?.recordStartupStage("root_overlay_mini_content_updated")
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
        let needsFinalReaderLayout = readerController.applyReaderPresentation(readerPresentationCoordinator.state,
            animated: viewportTransition != nil && !isCommittingInitialReaderPresentation)
        readerOpenStageProfiler?.recordStartupStage("root_reader_presentation_applied")
        applyReaderChromeLayout(
            viewportTransition: viewportTransition,
            needsFinalLayout: needsFinalReaderLayout
        )
        let miniShouldBeVisible = readerActive
            ? readerPresentationCoordinator.state.showsMiniPlayer(bookHasPlayback: showMini)
            : showMini
        if shellController.supportsSystemBottomAccessory, !readerActive {
            shellController.setSystemMiniPlayerVisible(miniShouldBeVisible, animated: true)
            miniPlayerPresentation.hideImmediately()
        } else {
            shellController.setSystemMiniPlayerVisible(false, animated: false)
            miniPlayerPresentation.setVisible(
                visible: miniShouldBeVisible,
                animated: !isCommittingInitialReaderPresentation
            )
        }
        if playerPresentation.showingFullPlayer {
            ensureFullPlayerController()
        }
        fullPlayerController?.setPresented(playerPresentation.showingFullPlayer,
            animated: !isCommittingInitialReaderPresentation)
        readerOpenStageProfiler?.recordStartupStage("root_overlay_visibility_updated")
        presentPlayerErrorIfNeeded()
        readerOpenStageProfiler?.recordStartupStage("root_overlay_refresh_completed")
    }

    /// The overlay has exactly one vertical owner. Keeping both anchors active
    /// during a tab-bar transition collapses the mini player to the tab bar's
    /// height and forces UIKit to break its content constraints.
    private func setMiniPlayerBottomAnchor(readerActive: Bool) {
        NSLayoutConstraint.deactivate([miniBottomToRoot, miniBottomToTabBar])
        (readerActive ? miniBottomToRoot : miniBottomToTabBar).isActive = true
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

#endif
