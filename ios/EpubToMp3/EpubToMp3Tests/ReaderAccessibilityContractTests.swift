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
        let tools = ReaderTool.allCases.filter { $0 != .footnotes }.map(\.accessibilityIdentifier)
        for identifier in ["reader.content"] + tools {
            XCTAssertTrue(identifiers.contains(identifier), "Missing installed accessibility element: \(identifier)")
        }
#else
        XCTAssertEqual(harness.composition.textView.accessibilityIdentifier, "reader.content")
        let reader = BookOpenScreenController(book: harness.book,
            library: LibraryStore(defaults: harness.defaults), settings: harness.settings,
            bookmarkStore: harness.bookmarks, player: harness.player, sessionDefaults: harness.defaults)
        let item = UINavigationItem()
        reader.installNavigationBarButtonItems(in: item)
        let items = try XCTUnwrap(item.rightBarButtonItems)
        let identifiers = Set(items.compactMap(\.accessibilityIdentifier))
        for identifier in ["reader.more", "reader.settings.toggle"] {
            XCTAssertTrue(identifiers.contains(identifier))
        }
        XCTAssertEqual(items.count, 2)
        let menu = try XCTUnwrap(items.first?.menu)
        let tools = menu.children.compactMap { ($0 as? UIAction)?.identifier.rawValue }
        XCTAssertTrue(tools.contains("reader.voiceModels"))
        XCTAssertEqual(Set(tools), Set(ReaderTool.allCases.filter { $0 != .footnotes }.map(\.accessibilityIdentifier)))
        XCTAssertFalse(reader.isViewLoaded, "Reading action metadata must not open a source or start playback")
#endif
    }
}
