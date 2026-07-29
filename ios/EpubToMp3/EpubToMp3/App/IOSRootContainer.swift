#if os(iOS)
import Combine
import UIKit

@MainActor
final class AdaptiveMaterialView: UIVisualEffectView {
    init() {
        if #available(iOS 26.0, *) {
            super.init(effect: UIGlassEffect(style: .regular))
        } else {
            super.init(effect: UIBlurEffect(style: .systemMaterial))
        }
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
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
    private var readerBottomToMiniPlayer: NSLayoutConstraint!
    private var readerBottomToRoot: NSLayoutConstraint!
    private var miniBottomToRoot: NSLayoutConstraint!
    private var miniBottomToTabBar: NSLayoutConstraint!
    private var miniPlayerHeight: NSLayoutConstraint!
    private var isImmersiveReaderMode = false
    private var isReaderLoading = false
    private var overlayStateInitialized = false
    private var readerBottomChromeInitialized = false
    private var readerBottomChromeHidden = false

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
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

        miniPlayerHeight = miniPlayerController.view.heightAnchor.constraint(equalToConstant: 52)
        miniPlayerHeight.isActive = true

        miniBottomToRoot = miniPlayerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        miniBottomToTabBar = miniPlayerController.view.bottomAnchor.constraint(equalTo: shellController.tabBar.topAnchor, constant: -8)
        miniBottomToRoot.isActive = true
        miniBottomToTabBar.isActive = false

        readerBottomToMiniPlayer = readerController.view.bottomAnchor.constraint(equalTo: miniPlayerController.view.topAnchor)
        readerBottomToRoot = readerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        readerBottomToMiniPlayer.isActive = true
        readerController.onReaderChromeVisibilityChanged = { [weak self] isHidden in
            self?.setImmersiveReaderMode(isHidden)
        }
        readerController.onReaderLoadingChanged = { [weak self] isLoading in
            self?.setReaderLoadingMode(isLoading)
        }

        miniPlayerController.view.backgroundColor = .clear
        fullPlayerController.view.backgroundColor = .clear

        bindState()
        updateTheme(settings.readerTheme)
        refreshOverlayState()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        miniPlayerHeight?.constant = 52 + view.safeAreaInsets.bottom
    }

    private func setImmersiveReaderMode(_ isHidden: Bool) {
        isImmersiveReaderMode = isHidden
        refreshOverlayState()
        if isHidden {
            // Keep the external playback chrome in sync with the reader's
            // immersive state even while a page transition is in progress.
            animateMiniPlayerVisibility(visible: false)
        }
    }

    private func setReaderLoadingMode(_ isLoading: Bool) {
        isReaderLoading = isLoading
        refreshOverlayState()
    }

    private func applyReaderChromeLayout() {
        let hidesBottomChrome = isReaderLoading || isImmersiveReaderMode
        readerBottomToMiniPlayer.isActive = !hidesBottomChrome
        readerBottomToRoot.isActive = hidesBottomChrome

        let changed = !readerBottomChromeInitialized || readerBottomChromeHidden != hidesBottomChrome
        readerBottomChromeInitialized = true
        readerBottomChromeHidden = hidesBottomChrome
        guard changed else { return }
        guard view.window != nil else {
            view.layoutIfNeeded()
            return
        }
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
            self.view.layoutIfNeeded()
        }
    }

    func updateTheme(_ theme: ReaderTheme) {
        shellController.applyTheme(theme)
        readerController.update(
            library: library,
            settings: settings,
            onBrowseLibrary: {
                ReaderSessionState.setCurrentlyReading(bookID: nil)
            }
        )
        miniPlayerController.update(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: { [weak self] in
                self?.playerPresentation.showFullPlayer()
            }
        )
        fullPlayerController.refresh(library: library)
        switch theme.preferredColorScheme {
        case .dark:
            overrideUserInterfaceStyle = .dark
        case .light:
            overrideUserInterfaceStyle = .light
        case nil:
            overrideUserInterfaceStyle = .unspecified
        @unknown default:
            overrideUserInterfaceStyle = .unspecified
        }
    }

    func refreshOverlayState() {
        let currentBookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let currentlyReadingBookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let availableBookIDs = Set(library.books.map(\.id))
        let readerActive = currentlyReadingBookID.flatMap { id in availableBookIDs.contains(id) ? id : nil } != nil
        let showMini = IOSMiniPlayerPolicy.shouldShow(
            currentBookID: currentBookID,
            currentlyReadingBookID: currentlyReadingBookID,
            availableBookIDs: availableBookIDs
        )

        readerController.view.isHidden = !readerActive
        // The reader owns the full screen while open. The library/settings/
        // conversion tabs must not remain visible underneath its player bar.
        shellController.tabBar.isHidden = readerActive
        miniBottomToTabBar.isActive = !readerActive
        miniBottomToRoot.isActive = readerActive
        if !readerActive {
            isImmersiveReaderMode = false
            isReaderLoading = false
        }
        applyReaderChromeLayout()
        let miniShouldBeVisible = showMini && !isReaderLoading && !isImmersiveReaderMode
        animateMiniPlayerVisibility(visible: miniShouldBeVisible)
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
            self.view.layoutIfNeeded()
        }
        let completion: (Bool) -> Void = { _ in
            if !visible {
                self.miniPlayerController.view.isHidden = true
            }
        }

        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
            animations: animations,
            completion: completion
        )
    }

    private func bindState() {
        playerPresentation.objectWillChange
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
        onTap: @escaping () -> Void
    ) {
        miniPlayerView.configure(
            player: player,
            playbackClock: playbackClock,
            library: library,
            onTap: onTap
        )
    }
}
#endif
