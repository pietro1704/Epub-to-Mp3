import XCTest
@testable import EpubToMp3

#if os(iOS)
import UIKit
#endif

final class IOSMiniPlayerPolicyTests: XCTestCase {
    @MainActor
    func testMiniPlayerShowsWhenPlayableBookExistsOutsideReader() {
        let visible = IOSMiniPlayerPolicy.shouldShow(
            currentBookID: "book-1",
            currentlyReadingBookID: nil,
            availableBookIDs: ["book-1", "book-2"]
        )

        XCTAssertTrue(visible)
    }

    /// The mini player is the reader's only "listen" trigger (no separate
    /// "Ouvir" button) — it must stay visible even while its book matches
    /// the one being read, not just before/after.
    @MainActor
    func testMiniPlayerShowsWhileReadingEvenIfItOwnsCurrentBook() {
        let visible = IOSMiniPlayerPolicy.shouldShow(
            currentBookID: "book-1",
            currentlyReadingBookID: "book-1",
            availableBookIDs: ["book-1", "book-2"]
        )

        XCTAssertTrue(visible)
    }

    @MainActor
    func testMiniPlayerShowsWhileReadingBeforeAnyPlaybackStarted() {
        let visible = IOSMiniPlayerPolicy.shouldShow(
            currentBookID: nil,
            currentlyReadingBookID: "book-1",
            availableBookIDs: ["book-1", "book-2"]
        )

        XCTAssertTrue(visible)
    }

    @MainActor
    func testMiniPlayerHidesWhenCurrentBookIsMissingFromLibrary() {
        let visible = IOSMiniPlayerPolicy.shouldShow(
            currentBookID: "book-1",
            currentlyReadingBookID: nil,
            availableBookIDs: ["book-2"]
        )

        XCTAssertFalse(visible)
    }
}

#if os(iOS)
final class IOSAppShellTests: XCTestCase {
    @MainActor
    func testUIKitShellTabOrderMatchesAppContract() {
        XCTAssertEqual(IOSAppShellTab.allCases, [.library, .settings, .convert])
        XCTAssertEqual(IOSAppShellTab.allCases.map(\.systemImage), [
            "books.vertical",
            "gearshape",
            "wand.and.stars",
        ])
    }

    @MainActor
    func testUIKitShellBuildsOneNavigationControllerPerTab() {
        let controller = IOSAppShellController(
            settings: AppSettings(),
            library: LibraryStore(),
            player: AudioPlayer(),
            playerPresentation: PlayerPresentation(),
            bookmarkStore: BookmarkStore()
        )

        let navigationControllers = controller.viewControllers as? [UINavigationController]
        XCTAssertEqual(navigationControllers?.count, IOSAppShellTab.allCases.count)
        XCTAssertEqual(
            navigationControllers?.compactMap(\.tabBarItem.title),
            IOSAppShellTab.allCases.map(\.title)
        )
    }

    @MainActor
    func testUIKitShellUsesUIKitRootControllersForMainTabs() {
        let controller = IOSAppShellController(
            settings: AppSettings(),
            library: LibraryStore(),
            player: AudioPlayer(),
            playerPresentation: PlayerPresentation(),
            bookmarkStore: BookmarkStore()
        )

        let navigationControllers = controller.viewControllers as? [UINavigationController]
        XCTAssertTrue(navigationControllers?[0].viewControllers.first is LibraryScreenController)
        XCTAssertTrue(navigationControllers?[1].viewControllers.first is SettingsScreenController)
        XCTAssertTrue(navigationControllers?[2].viewControllers.first is ConvertScreenController)
    }

#if compiler(>=6.2)
    @available(iOS 18.0, *)
    @MainActor
    func testIPadUsesNativeTabSidebarWhileIPhoneKeepsTabBar() {
        let controller = makeShellController()

        controller.configureNavigationMode(for: .pad)
        XCTAssertEqual(controller.mode, .tabSidebar)

        controller.configureNavigationMode(for: .phone)
        XCTAssertEqual(controller.mode, .tabBar)
    }
#endif

#if compiler(>=6.2)
    @available(iOS 26.0, *)
    @MainActor
    func testSystemBottomAccessoryHostsTheMiniPlayerOutsideTheReader() {
        let controller = makeShellController()
        let miniPlayerContent = UIView()

        controller.setMiniPlayerAccessoryContent(
            miniPlayerContent,
            visible: true,
            animated: false
        )

        XCTAssertTrue(controller.usesSystemBottomAccessory)
        XCTAssertTrue(controller.bottomAccessory?.contentView === miniPlayerContent)

        controller.setMiniPlayerAccessoryContent(nil, visible: false, animated: false)

        XCTAssertFalse(controller.usesSystemBottomAccessory)
        XCTAssertNil(controller.bottomAccessory)
    }
#endif

    @MainActor
    private func makeShellController() -> IOSAppShellController {
        IOSAppShellController(
            settings: AppSettings(),
            library: LibraryStore(),
            player: AudioPlayer(),
            playerPresentation: PlayerPresentation(),
            bookmarkStore: BookmarkStore()
        )
    }
}
#endif
