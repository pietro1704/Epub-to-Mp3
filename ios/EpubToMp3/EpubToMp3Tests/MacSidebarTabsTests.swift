#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

/// PARITY-MAC-SETTINGS-1: the sidebar has the iPhone's three tabs; as on Linux, the conversions
/// list opens from the Convert screen.
@MainActor
final class MacSidebarTabsTests: XCTestCase {
    func testSidebarHasTheiPhoneTabsInOrder() throws {
        try withRoot { sidebar, _ in
            XCTAssertEqual(buttons(in: sidebar()).map(\.title),
                           [L10n.string("nav.library"), L10n.string("nav.settings"), L10n.string("convert.title")])
        }
    }

    func testConvertScreenOpensTheConversionsListAndReturns() throws {
        try withRoot { sidebar, detail in
            let convert = try XCTUnwrap(buttons(in: sidebar()).first { $0.title == L10n.string("convert.title") })
            convert.performClick(nil)
            let converter = try XCTUnwrap(detail().children.last as? MacConvertScreenController)
            let history = try XCTUnwrap(buttons(in: converter.view)
                .first { $0.accessibilityIdentifier() == "convert.history" }, "missing conversions button")
            XCTAssertEqual(history.accessibilityLabel(), L10n.string("jobs.title"))
            history.performClick(nil)
            XCTAssertTrue(detail().children.last is MacJobsListViewController)
            XCTAssertEqual(convert.state, .on, "the conversions list belongs to the Convert tab")
            convert.performClick(nil)
            XCTAssertTrue(detail().children.last === converter)
        }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? buttons(in: child)
        }
    }

    private func withRoot(_ body: (() -> NSView, () -> NSViewController) throws -> Void) throws {
        let suite = "mac-sidebar-tabs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = MacAppKitRootController(
            settings: AppSettings(defaults: defaults), library: LibraryStore(defaults: defaults, defaultsKey: "library"),
            player: AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)), location: .standard),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = root
        defer { window.contentViewController = nil; window.close() }
        window.layoutIfNeeded()
        try body({ root.splitViewItems[0].viewController.view }, { root.splitViewItems[1].viewController })
    }
}
#endif
