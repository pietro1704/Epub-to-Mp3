import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ReaderAccessibilityContractTests: XCTestCase {
    func testNativeReaderInstallsStableContentAndNavigationIdentifiers() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Readable")])
        harness.installTeardown(in: self)
#if os(macOS)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let identifiers = Set(descendants(harness.controller.view).compactMap { $0.accessibilityIdentifier() })
        for identifier in ["reader.content", "reader.more"] {
            XCTAssertTrue(identifiers.contains(identifier), "Missing installed accessibility element: \(identifier)")
        }
        let more = try XCTUnwrap(descendants(harness.controller.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "reader.more" })
        let tools = try XCTUnwrap(more.menu).items.compactMap { $0.representedObject as? String }
        XCTAssertEqual(Set(tools), Set(ReaderTool.allCases.map(\.rawValue)))
#else
        XCTAssertEqual(harness.composition.textView.accessibilityIdentifier, "reader.content")
        let reader = BookOpenScreenController(book: harness.book,
            library: LibraryStore(defaults: harness.defaults), settings: harness.settings,
            bookmarkStore: harness.bookmarks, player: harness.player, sessionDefaults: harness.defaults)
        let identifiers = Set(reader.navigationBarButtonItems.compactMap(\.accessibilityIdentifier))
        for identifier in ["reader.more", "reader.settings.toggle"] {
            XCTAssertTrue(identifiers.contains(identifier))
        }
        XCTAssertEqual(reader.navigationBarButtonItems.count, 2)
        let menu = try XCTUnwrap(reader.navigationBarButtonItems.first?.menu)
        XCTAssertEqual(menu.children.count, ReaderTool.allCases.count)
        XCTAssertFalse(reader.isViewLoaded, "Reading action metadata must not open a source or start playback")
#endif
    }
}
