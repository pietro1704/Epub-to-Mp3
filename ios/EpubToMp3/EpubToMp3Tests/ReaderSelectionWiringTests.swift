import XCTest
@testable import EpubToMp3
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ReaderSelectionWiringTests: XCTestCase {
    func testNativeHighlightActionPersistsTheDisplayedSelectionAndRepaintsIt() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Before selected passage after.")])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        let range = (harness.displayed.string as NSString).range(of: "selected passage")
#if os(macOS)
        let items = harness.annotations.buildSelectionMenuItems(range: range)
        XCTAssertEqual(items.map(\.title), [L10n.string("reader.action.highlight"), L10n.string("reader.action.addNote")])
        let item = try XCTUnwrap(items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
#else
        if #available(iOS 16.0, *) {
            let menu = try XCTUnwrap(harness.annotations.textView(harness.composition.textView,
                editMenuForTextIn: range, suggestedActions: []))
            let actions = try XCTUnwrap(menu.children.first as? UIMenu).children.compactMap { $0 as? UIAction }
            XCTAssertEqual(actions.map(\.title), [L10n.string("reader.action.highlight"), L10n.string("reader.action.addNote")])
            let button = UIButton()
            button.addAction(try XCTUnwrap(actions.first), for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
        } else {
            throw XCTSkip("Native selection menus require iOS 16")
        }
#endif
        let bookmark = try XCTUnwrap(harness.bookmarks.bookmarks(for: harness.id).first)
        XCTAssertEqual(bookmark.selectedText, "selected passage")
        XCTAssertEqual(bookmark.chapterIndex, 0)
        XCTAssertEqual(bookmark.startChar, range.location)
        XCTAssertEqual(bookmark.endChar, NSMaxRange(range))
        XCTAssertNotNil(harness.displayed.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
        harness.showChapter(0)
        XCTAssertNotNil(harness.displayed.attribute(.backgroundColor, at: range.location, effectiveRange: nil),
                        "Saved highlights must survive chapter rerendering")
    }
}
