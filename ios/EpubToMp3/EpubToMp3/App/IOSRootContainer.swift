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

@MainActor
final class IOSRootContainerController: UIViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore

    private let shellController: IOSAppShellController
    private let readerController: MainReaderScreenController
    private let miniPlayerController: MiniPlayerContainerController
    private let fullPlayerController: FullPlayerScreenController

    private var cancellables: Set<AnyCancellable> = []
    private var presentedErrorMessage: String?
    private var miniBottomToRoot: NSLayoutConstraint!
    private var miniBottomToTabBar: NSLayoutConstraint!
    private var miniPlayerMaximumHeight: NSLayoutConstraint!
    private let readerPresentationCoordinator = ReaderRootPresentationCoordinator()
    private var overlayStateInitialized = false

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
            }
        )
        self.miniPlayerController = MiniPlayerContainerController(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: {
                playerPresentation.showFullPlayer()
            }
        )
        self.fullPlayerController = FullPlayerScreenController(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            playerPresentation: playerPresentation,
            settings: settings
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
        view.backgroundColor = .systemBackground
        hydrateCachedChapterTitles()
        restoreLocalPlaybackControls()
        Task.detached(priority: .utility) {
            LocalFulltextCache.prewarmRecentBooks()
        }
        embed(shellController)
        embed(readerController)
        embed(miniPlayerController)
        embed(fullPlayerController)

        shellController.view.translatesAutoresizingMaskIntoConstraints = false
        readerController.view.translatesAutoresizingMaskIntoConstraints = false
        miniPlayerController.view.translatesAutoresizingMaskIntoConstraints = false
        fullPlayerController.view.translatesAutoresizingMaskIntoConstraints = false

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

            fullPlayerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fullPlayerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fullPlayerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            fullPlayerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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

        miniPlayerController.view.backgroundColor = .clear
        fullPlayerController.view.backgroundColor = .clear
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
        updateTheme(settings.readerTheme)
        refreshOverlayState()
    }

    private func setImmersiveReaderMode(_ isHidden: Bool) {
        let token = readerPresentationCoordinator.beginChromeTransition(to: isHidden) { [weak self] in
            self?.readerController.captureReaderViewportTransition()
        }
        setNeedsStatusBarAppearanceUpdate()
        refreshOverlayState(viewportTransition: token)
    }

    private func setReaderLoadingMode(_ isLoading: Bool) {
        guard readerPresentationCoordinator.setLoading(isLoading) else { return }
        setNeedsStatusBarAppearanceUpdate()
        refreshOverlayState()
    }

    private func refreshMiniPlayerContent() {
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
    }

    private func applyReaderChromeLayout(
        viewportTransition: ReaderViewportTransition.Token? = nil,
        needsFinalLayout: Bool = false
    ) {
        readerPresentationCoordinator.applyChromeLayout(
            transition: viewportTransition,
            needsFinalLayout: needsFinalLayout,
            restoreViewport: { [weak self] in self?.readerController.completeReaderChromeLayoutTransition() }
        )
    }

    private func showFullPlayer() {
        playerPresentation.showFullPlayer()
        refreshOverlayState()
    }

    func updateTheme(_ theme: ReaderTheme) {
        let colors = theme.previewColors
        view.backgroundColor = colors.background
        miniPlayerController.applyReaderBackground(colors.background)
        shellController.applyTheme(theme)
        readerController.update(
            library: library,
            settings: settings,
            onBrowseLibrary: { [weak self] in self?.dismissReaderToLibrary() }
        )
        refreshMiniPlayerContent()
        fullPlayerController.refresh(library: library)
        switch theme.preferredColorScheme {
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
        let bookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
            ?? UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        guard let bookID else { return }
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
                engine: "edge",
                voice: "auto",
                language: nil
            )
            let remoteSnapshot = library.books.first(where: { $0.id == bookID })?.lastJobId
                .flatMap(DownloadManager.localPlaybackSnapshot(jobId:))
            guard let snapshot = embeddedSnapshot ?? remoteSnapshot else {
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
        refreshMiniPlayerContent()
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
        shellController.setReaderTabBarHidden(readerActive, animated: true)
        setMiniPlayerBottomAnchor(readerActive: readerActive)
        if !readerActive {
            if wasImmersive {
                setNeedsStatusBarAppearanceUpdate()
            }
        }
        let needsFinalReaderLayout = readerController.applyReaderPresentation(readerPresentationCoordinator.state)
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
            animateMiniPlayerVisibility(visible: miniShouldBeVisible)
        }
        fullPlayerController.view.isHidden = !playerPresentation.showingFullPlayer
        fullPlayerController.view.alpha = playerPresentation.showingFullPlayer ? 1 : 0
        presentPlayerErrorIfNeeded()
    }

    private func animateMiniPlayerVisibility(visible: Bool) {
        let wasVisible = overlayStateInitialized && !miniPlayerController.view.isHidden
            && miniPlayerController.view.alpha > 0.01
        let changed = !overlayStateInitialized || wasVisible != visible
        overlayStateInitialized = true
        guard changed else { return }

        if visible {
            miniPlayerController.view.isHidden = false
            miniPlayerController.view.alpha = 0
        }

        let animations = {
            self.miniPlayerController.view.alpha = visible ? 1 : 0
        }
        let completion: (Bool) -> Void = { _ in
            if !visible {
                self.miniPlayerController.view.isHidden = true
            }
        }

        UIView.animate(
            withDuration: ReaderChromeTransitionMetrics.duration,
            delay: 0,
            options: ReaderChromeTransitionMetrics.animationOptions,
            animations: animations,
            completion: completion
        )
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
