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
        for identifier in ["reader.content", "reader.toc.toggle", "reader.search", "reader.settings.toggle"] {
            XCTAssertTrue(identifiers.contains(identifier), "Missing installed accessibility element: \(identifier)")
        }
        XCTAssertFalse(identifiers.contains("reader.footnotes"))
#else
        XCTAssertEqual(harness.composition.textView.accessibilityIdentifier, "reader.content")
        let reader = BookOpenScreenController(book: harness.book,
            library: LibraryStore(defaults: harness.defaults), settings: harness.settings,
            bookmarkStore: harness.bookmarks, player: harness.player)
        let identifiers = Set(reader.navigationBarButtonItems.compactMap(\.accessibilityIdentifier))
        for identifier in ["reader.toc.toggle", "reader.search", "reader.settings.toggle"] {
            XCTAssertTrue(identifiers.contains(identifier))
        }
        XCTAssertFalse(reader.isViewLoaded, "Reading action metadata must not open a source or start playback")
#endif
    }
}
