#if os(macOS)
import AppKit
import XCTest
@testable import EpubToMp3

final class MacPlayerBarAccessibilityTests: XCTestCase {
    @MainActor
    func testVisiblePlayerRemainsAnAccessibilityChildAlongsideLibraryContent() throws {
        let suite = "MacPlayerAccessibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayer()
        defer { player.stop() }
        player.setSnapshot(try JSONDecoder().decode(JobSnapshot.self, from:
            Data(#"{"jobId":"accessibility","state":"failed","bookTitle":"Fixture","error":"Unavailable voice"}"#.utf8)))
        let root = MacAppKitRootController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults))
        let window = NSWindow(contentViewController: root)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        root.view.layoutSubtreeIfNeeded()
        let detail = try XCTUnwrap(root.splitViewItems.last?.viewController.view)
        func hasTransport(_ view: NSView) -> Bool {
            if let button = view as? NSButton, button.action == NSSelectorFromString("togglePlayback") { return true }
            return view.subviews.contains(where: hasTransport)
        }
        let bar = try XCTUnwrap(detail.subviews.first(where: hasTransport))
        XCTAssertFalse(bar.isHidden)
        XCTAssertTrue((detail.accessibilityChildren() ?? []).contains { ($0 as? NSView) === bar },
                      "The explicit detail accessibility tree must include the persistent transport")
    }
}
#endif
