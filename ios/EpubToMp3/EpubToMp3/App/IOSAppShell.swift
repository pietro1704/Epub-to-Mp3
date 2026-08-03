#if os(iOS)
import UIKit

enum IOSAppShellTab: Int, CaseIterable {
    case library
    case settings
    case convert

    var title: String {
        switch self {
        case .library:
            return L10n.string("nav.library")
        case .settings:
            return L10n.string("nav.settings")
        case .convert:
            return L10n.string("convert.title")
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            return "books.vertical"
        case .settings:
            return "gearshape"
        case .convert:
            return "wand.and.stars"
        }
    }
}

final class IOSAppShellController: UITabBarController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore
    private var miniPlayerAccessoryView: MiniPlayerBarUIKitView?
    private var miniPlayerAccessory: NSObject?

    private(set) var usesSystemBottomAccessory = false

    var supportsSystemBottomAccessory: Bool {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
#endif
        return false
    }

    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore
    ) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        super.init(nibName: nil, bundle: nil)
        viewControllers = IOSAppShellTab.allCases.map(makeNavigationController(for:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigationMode(
            for: UIDevice.current.userInterfaceIdiom,
            horizontalSizeClass: traitCollection.horizontalSizeClass
        )
    }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.configureNavigationMode(
                for: UIDevice.current.userInterfaceIdiom,
                horizontalSizeClass: self.traitCollection.horizontalSizeClass
            )
        }
    }

    func applyTheme(_ theme: ReaderTheme) {
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

    func configureMiniPlayerAccessory(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void,
        onPlayRequested: @escaping () -> Void
    ) {
#if compiler(>=6.2)
        guard #available(iOS 26.0, *) else { return }
        let miniPlayerView = MiniPlayerBarUIKitView(usesSystemManagedBottomInset: true)
        miniPlayerView.configure(
            player: player,
            playbackClock: playbackClock,
            library: library,
            onTap: onTap,
            onPlayRequested: onPlayRequested
        )
        miniPlayerAccessoryView = miniPlayerView
#endif
    }

    func setSystemMiniPlayerVisible(_ visible: Bool, animated: Bool) {
        setMiniPlayerAccessoryContent(
            miniPlayerAccessoryView,
            visible: visible,
            animated: animated
        )
    }

    func refreshMiniPlayerAccessory(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void,
        onPlayRequested: @escaping () -> Void
    ) {
        miniPlayerAccessoryView?.configure(
            player: player,
            playbackClock: playbackClock,
            library: library,
            onTap: onTap,
            onPlayRequested: onPlayRequested
        )
    }

    func setReaderTabBarHidden(_ hidden: Bool, animated: Bool) {
        if #available(iOS 18.0, *) {
            setTabBarHidden(hidden, animated: animated)
        } else {
            tabBar.isHidden = hidden
        }
    }

    func configureNavigationMode(
        for interfaceIdiom: UIUserInterfaceIdiom,
        horizontalSizeClass: UIUserInterfaceSizeClass = .regular
    ) {
        guard #available(iOS 18.0, *) else { return }
        mode = interfaceIdiom == .pad && horizontalSizeClass == .regular
            ? .tabSidebar
            : .tabBar
    }

    func setMiniPlayerAccessoryContent(
        _ contentView: UIView?,
        visible: Bool,
        animated: Bool
    ) {
#if compiler(>=6.2)
        guard #available(iOS 26.0, *) else {
            usesSystemBottomAccessory = false
            return
        }

        guard visible, let contentView else {
            setBottomAccessory(nil, animated: animated)
            miniPlayerAccessory = nil
            usesSystemBottomAccessory = false
            return
        }

        let accessory = miniPlayerAccessory as? UITabAccessory
        let resolvedAccessory: UITabAccessory
        if let accessory, accessory.contentView === contentView {
            resolvedAccessory = accessory
        } else {
            resolvedAccessory = UITabAccessory(contentView: contentView)
            miniPlayerAccessory = resolvedAccessory
        }
        setBottomAccessory(resolvedAccessory, animated: animated)
        usesSystemBottomAccessory = true
#else
        usesSystemBottomAccessory = false
#endif
    }

    private func makeNavigationController(for tab: IOSAppShellTab) -> UINavigationController {
        let rootController: UIViewController
        switch tab {
        case .library:
            rootController = LibraryScreenController(
                library: library,
                settings: settings,
                player: player,
                playerPresentation: playerPresentation,
                bookmarkStore: bookmarkStore
            )
        case .settings:
            rootController = SettingsScreenController(
                settings: settings,
                library: library,
                player: player,
                playbackClock: player.playbackClock
            )
        case .convert:
            rootController = ConvertScreenController(
                settings: settings,
                library: library,
                player: player,
                playbackClock: player.playbackClock
            )
        }

        rootController.title = tab.title
        let navigationController = UINavigationController(rootViewController: rootController)
        let tabBarItem = UITabBarItem(
            title: tab.title,
            image: UIImage(systemName: tab.systemImage),
            tag: tab.rawValue
        )
        tabBarItem.accessibilityIdentifier = "tab.\(tab)"
        navigationController.tabBarItem = tabBarItem
        return navigationController
    }
}
#endif
