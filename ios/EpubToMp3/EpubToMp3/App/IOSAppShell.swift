#if os(iOS)
import SwiftUI
import UIKit

struct IOSAppShell: UIViewControllerRepresentable {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var readerCoordinator: ReaderCoordinator
    @EnvironmentObject private var audioWarmup: AudioEngineWarmup

    func makeUIViewController(context: Context) -> IOSAppShellController {
        let controller = IOSAppShellController(
            settings: settings,
            library: library,
            player: player,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore,
            readerCoordinator: readerCoordinator,
            audioWarmup: audioWarmup
        )
        controller.applyTheme(settings.readerTheme)
        return controller
    }

    func updateUIViewController(_ controller: IOSAppShellController, context: Context) {
        controller.applyTheme(settings.readerTheme)
    }
}

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
    private let readerCoordinator: ReaderCoordinator
    private let audioWarmup: AudioEngineWarmup

    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore,
        readerCoordinator: ReaderCoordinator,
        audioWarmup: AudioEngineWarmup
    ) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        self.readerCoordinator = readerCoordinator
        self.audioWarmup = audioWarmup
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
            rootController = UIHostingController(
                rootView: LibraryView()
                    .environmentObject(library)
                    .environmentObject(settings)
                    .environmentObject(bookmarkStore)
                    .environmentObject(player)
                    .environmentObject(playerPresentation)
                    .environmentObject(readerCoordinator)
            )
        case .settings:
            rootController = UIHostingController(
                rootView: SettingsView()
                    .environmentObject(settings)
                    .environmentObject(library)
                    .environmentObject(player)
                    .environmentObject(playerPresentation)
                    .environmentObject(readerCoordinator)
                    .environmentObject(audioWarmup)
            )
        case .convert:
            rootController = UIHostingController(
                rootView: ConvertView()
                    .environmentObject(settings)
                    .environmentObject(library)
                    .environmentObject(player)
                    .environmentObject(playerPresentation)
                    .environmentObject(readerCoordinator)
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
