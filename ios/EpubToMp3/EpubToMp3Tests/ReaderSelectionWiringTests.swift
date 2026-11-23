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
        // Since #1152 the Mac menu leads with Play from here and groups the
        // highlight actions under More.
        let items = harness.annotations.buildSelectionMenuItems(range: range)
        XCTAssertEqual(items.map(\.title), [L10n.string("reader.action.playFromHere"), L10n.string("reader.selection.more")])
        let more = try XCTUnwrap(items.last?.submenu)
        XCTAssertEqual(Array(more.items.prefix(2)).map(\.title),
                       [L10n.string("reader.action.highlight"), L10n.string("reader.action.addNote")])
        let item = try XCTUnwrap(more.items.first)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
#else
        if #available(iOS 16.0, *) {
            let menu = try XCTUnwrap(harness.annotations.textView(harness.composition.textView,
                editMenuForTextIn: range, suggestedActions: []))
            // Like the Mac since #1152: Play from here first, the highlight actions under More.
            XCTAssertEqual(menu.children.prefix(2).map(\.title),
                           [L10n.string("reader.action.playFromHere"), L10n.string("reader.selection.more")])
            let more = try XCTUnwrap(menu.children.dropFirst().first as? UIMenu)
            let actions = Array(more.children.compactMap { $0 as? UIAction }.prefix(2))
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

    /// PLAY-FROM-HERE-CLEARS-SELECTION: Play from here leaves the selection mode (the selection is cleared and the
    /// edit menu closes) and narration starts from there; the selected text must not stay highlighted behind it.
    func testPlayFromHereClearsTheSelectionAndStartsFromThere() throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Before selected passage after.")])
        harness.installTeardown(in: self)
        harness.showChapter(0)
        let range = (harness.displayed.string as NSString).range(of: "selected passage")
        var started: [(chapter: Int, ratio: Double)] = []
        harness.annotations.onPlayFromHere = { started.append(($0, $1)) }
#if os(macOS)
        let textView = harness.composition.textView
        textView.setSelectedRange(range)
        let play = try XCTUnwrap(harness.annotations.buildSelectionMenuItems(range: range).first)
        XCTAssertEqual(play.title, L10n.string("reader.action.playFromHere"))
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(play.action), to: play.target, from: play))
        XCTAssertEqual(textView.selectedRange().length, 0, "Play from here must leave the selection mode")
#else
        guard #available(iOS 16.0, *) else { throw XCTSkip("Native selection menus require iOS 16") }
        let textView = harness.composition.textView
        textView.selectedRange = range
        let menu = try XCTUnwrap(harness.annotations.textView(textView, editMenuForTextIn: range, suggestedActions: []))
        let play = try XCTUnwrap(menu.children.first as? UIAction)
        XCTAssertEqual(play.title, L10n.string("reader.action.playFromHere"))
        let button = UIButton()
        button.addAction(play, for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(textView.selectedRange.length, 0, "Play from here must leave the selection mode")
#endif
        XCTAssertEqual(started.count, 1, "...and narration starts from the selected text")
        XCTAssertEqual(started.first?.chapter, 0)
        XCTAssertNotNil(started.first.map { $0.ratio }.flatMap { $0 > 0 ? $0 : nil }, "from the selection, not the chapter start")
    }
}
