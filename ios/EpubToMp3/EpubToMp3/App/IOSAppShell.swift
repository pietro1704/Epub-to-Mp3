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

    private func makeNavigationController(for tab: IOSAppShellTab) -> UINavigationController {
        let rootController: UIViewController
        switch tab {
        case .library:
            rootController = LibraryScreenController(
                library: library,
                settings: settings,
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
        navigationController.tabBarItem = UITabBarItem(
            title: tab.title,
            image: UIImage(systemName: tab.systemImage),
            tag: tab.rawValue
        )
        return navigationController
    }
}
#endif
