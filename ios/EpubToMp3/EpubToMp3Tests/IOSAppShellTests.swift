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
    func testIOSAppShellFileKeepsOnlyUIKitControllerEntryPoint() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/IOSAppShell.swift")
        )

        XCTAssertFalse(source.contains("struct IOSAppShell: UIViewControllerRepresentable"))
        XCTAssertTrue(source.contains("final class IOSAppShellController: UITabBarController"))
    }

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
    func testReaderOverlayRemainsOpaqueAboveTheLibrary() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/IOSRootContainer.swift")
        )

        XCTAssertFalse(
            source.contains("readerController.view.backgroundColor = .clear"),
            "An active reader must not reveal the library through a transparent overlay."
        )
    }

    @MainActor
    func testMiniPlayerExposesAutomationIdentifiers() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Views/MiniPlayerBarHost.swift")
        )

        XCTAssertTrue(source.contains("miniPlayer.bar"))
        XCTAssertTrue(source.contains("miniPlayer.playPause"))
    }

    @MainActor
    func testMainAppContainsNoSwiftUIScreensOrHostingBridges() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
        let swiftFiles = (FileManager.default
            .subpaths(atPath: appRoot.path) ?? [])
            .compactMap { relativePath -> URL? in
                guard relativePath.hasSuffix(".swift") else { return nil }
                return appRoot.appendingPathComponent(relativePath)
            }

        for file in swiftFiles {
            let source = try readSourceFileIfAvailable(at: file)
            XCTAssertFalse(source.contains("import SwiftUI"), "UIKit/AppKit app must not import SwiftUI: \(file.lastPathComponent)")
            XCTAssertFalse(source.contains("UIHostingController"), "UIKit app must not host SwiftUI screens: \(file.lastPathComponent)")
            XCTAssertFalse(source.contains("NSHostingController"), "AppKit app must not host SwiftUI screens: \(file.lastPathComponent)")
        }
    }

    @MainActor
    func testUIKitShellThreadsPlaybackDependenciesIntoSettingsFlow() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/App/IOSAppShell.swift")
        )

        XCTAssertTrue(source.contains("SettingsScreenController("))
        XCTAssertTrue(source.contains("player: player"))
        XCTAssertTrue(source.contains("playbackClock: player.playbackClock"))
        XCTAssertTrue(source.contains("ConvertScreenController("))
    }

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
