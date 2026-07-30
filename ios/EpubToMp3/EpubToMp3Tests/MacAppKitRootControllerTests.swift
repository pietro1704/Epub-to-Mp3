import XCTest
@testable import EpubToMp3

#if os(macOS)
import AppKit

@MainActor
final class MacAppKitRootControllerTests: XCTestCase {
    func testMainMenuProvidesNativeFileEditViewWindowAndHelpMenus() throws {
        let mainMenu = EpubToMp3App.makeMainMenu()
        let menuTitles = mainMenu.items.compactMap { $0.submenu?.title }

        XCTAssertEqual(
            menuTitles,
            [
                L10n.string("app.name"),
                L10n.string("menu.file"),
                L10n.string("menu.edit"),
                L10n.string("menu.view"),
                L10n.string("menu.window"),
                L10n.string("menu.help"),
            ]
        )

        let fileMenu = try XCTUnwrap(mainMenu.items[1].submenu)
        XCTAssertTrue(fileMenu.items.contains { $0.title == L10n.string("menu.importBook") && $0.keyEquivalent == "o" })

        let viewMenu = try XCTUnwrap(mainMenu.items[3].submenu)
        XCTAssertTrue(viewMenu.items.contains { $0.title == L10n.string("nav.toggleSidebar") })
        XCTAssertTrue(viewMenu.items.contains { $0.title == L10n.string("menu.searchLibrary") && $0.keyEquivalent == "f" })
    }

    func testToolbarSidebarItemCollapsesAndRestoresSidebarWithoutDetachingDetail() throws {
        let suiteName = "MacAppKitRootControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let root = MacAppKitRootController(
            settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library.\(suiteName)"),
            player: AudioPlayer(
                resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))
            ),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks.\(suiteName)"),
            playerPresentation: PlayerPresentation(defaults: defaults)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = root
        root.configureWindowToolbar(window)
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()

        let sidebarItem = try XCTUnwrap(
            window.toolbar?.items.first(where: {
                $0.itemIdentifier == MacAppKitRootController.sidebarToolbarItemIdentifier
            })
        )
        let detailView = root.splitViewItems[1].viewController.view
        XCTAssertFalse(root.splitViewItems[0].isCollapsed)
        XCTAssertNotNil(detailView.window)
        XCTAssertGreaterThan(detailView.frame.width, 0)

        XCTAssertTrue(
            NSApplication.shared.sendAction(sidebarItem.action!, to: sidebarItem.target, from: sidebarItem)
        )
        window.layoutIfNeeded()

        XCTAssertTrue(root.splitViewItems[0].isCollapsed)
        XCTAssertNotNil(detailView.window)
        XCTAssertGreaterThan(detailView.frame.width, 0)

        XCTAssertTrue(
            NSApplication.shared.sendAction(sidebarItem.action!, to: sidebarItem.target, from: sidebarItem)
        )
        window.layoutIfNeeded()

        XCTAssertFalse(root.splitViewItems[0].isCollapsed)
        XCTAssertEqual(root.splitViewItems.count, 2)
        XCTAssertNotNil(detailView.window)
        XCTAssertGreaterThan(detailView.frame.width, 0)
    }
}
#endif
