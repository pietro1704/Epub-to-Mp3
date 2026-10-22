#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderAppKitTests: XCTestCase {
    func testMacRootAndReaderUseInstalledNativeViews() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Native text")])
        harness.installTeardown(in: self)
        let root: NSViewController = MacAppKitRootController(settings: harness.settings,
            library: LibraryStore(defaults: harness.defaults), player: harness.player,
            bookmarkStore: harness.bookmarks, playerPresentation: PlayerPresentation(defaults: harness.defaults))
        let split = try XCTUnwrap(root as? NSSplitViewController)
        XCTAssertEqual(split.splitViewItems.count, 2)
        _ = root.view
        harness.showChapter(0)
        XCTAssertTrue(harness.composition.contentScrollView.documentView === harness.composition.textView)
        XCTAssertEqual(harness.composition.textView.string.trimmingCharacters(in: .whitespacesAndNewlines), "Native text")
        func descendants(_ controller: NSViewController) -> [NSViewController] {
            [controller] + controller.children.flatMap(descendants)
        }
        XCTAssertFalse(descendants(root).contains { String(reflecting: type(of: $0)).contains("HostingController") })
    }

    func testAppWindowCenteringUsesTheVisiblePrimaryScreen() throws {
        let visible = try XCTUnwrap(NSScreen.screens.first?.visibleFrame)
        let window = EpubToMp3WindowConfiguration.makeMacOSWindow()
        window.isReleasedWhenClosed = false
        defer { window.close() }
        EpubToMp3WindowConfiguration.centerOnActiveScreen(window)
        let expectedX = min(max(visible.midX - window.frame.width / 2, visible.minX), visible.maxX - window.frame.width)
        let expectedY = min(max(visible.midY - window.frame.height / 2, visible.minY), visible.maxY - window.frame.height)
        XCTAssertEqual(window.frame.minX, expectedX, accuracy: 1)
        XCTAssertEqual(window.frame.minY, expectedY, accuracy: 1)
        XCTAssertEqual(window.minSize, EpubToMp3WindowConfiguration.macOSMinimumSize)
        XCTAssertFalse(window.isRestorable)
    }
}
#endif
