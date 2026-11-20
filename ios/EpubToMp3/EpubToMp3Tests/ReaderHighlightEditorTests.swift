import Foundation
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderHighlightEditorTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var store: BookmarkStore!
    private var editor: ReaderHighlightEditor!
    private let text = NSAttributedString(string: "The quick brown fox jumps over the lazy dog.")

    override func setUp() {
        super.setUp()
        suite = "ReaderHighlightEditor.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = BookmarkStore(defaults: defaults)
        editor = ReaderHighlightEditor(store: store)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func select(_ range: NSRange, book: String = "book", chapter: Int = 3, title: String = "Three") -> ReaderHighlightEditor.Selection? {
        editor.selection(range: range, in: text, bookID: book, chapterIndex: chapter, chapterTitle: title)
    }

    func testInvalidRangesProduceNoSelection() {
        for range in [NSRange(location: NSNotFound, length: 3), NSRange(location: -1, length: 3),
                      NSRange(location: 4, length: 0), NSRange(location: 99, length: 2),
                      NSRange(location: 40, length: 20)] {
            XCTAssertNil(select(range), "\(range)")
        }
    }

    func testToggleAddsThenRemovesOnlyThatHighlightAndPersists() throws {
        let other = store.addBookmark(bookId: "book", chapterIndex: 3, chapterTitle: "Three",
                                      startChar: 35, endChar: 43, selectedText: "lazy dog")
        let selection = try XCTUnwrap(select(NSRange(location: 4, length: 5)))
        XCTAssertNil(selection.existing)
        XCTAssertEqual(selection.text, "quick")

        guard case .added(let added) = editor.toggleHighlight(selection) else { return XCTFail("expected added") }
        XCTAssertEqual([added.bookId, added.chapterTitle, added.selectedText], ["book", "Three", "quick"])
        XCTAssertEqual([added.startChar, added.endChar, added.chapterIndex], [4, 9, 3])
        XCTAssertEqual(added.color, .yellow)
        XCTAssertNil(added.note)
        XCTAssertEqual(BookmarkStore(defaults: defaults).bookmarks.count, 2, "survives a new store")

        let again = try XCTUnwrap(editor.selection(range: NSRange(location: 5, length: 3), in: text, bookID: "book",
                                                   chapterIndex: 3, chapterTitle: "Three"))
        XCTAssertEqual(again.existing?.id, added.id, "a partial selection inside a highlight targets it")
        guard case .removed(let id) = editor.toggleHighlight(again) else { return XCTFail("expected removed") }
        XCTAssertEqual(id, added.id)
        XCTAssertEqual(store.bookmarks.map(\.id), [other.id])
    }

    func testNoteIsStoredAgainstTheSelectionsChapterEvenIfTheReaderMovedOn() throws {
        let selection = try XCTUnwrap(select(NSRange(location: 10, length: 5), chapter: 3, title: "Three"))
        // The reader moved to chapter 4 while the note prompt was open.
        XCTAssertFalse(ReaderHighlightEditor.isCurrent(selection, bookID: "book", chapterIndex: 4))
        let saved = editor.addNote(selection, note: "remember")
        XCTAssertEqual(saved.chapterIndex, 3)
        XCTAssertEqual(saved.chapterTitle, "Three")
        XCTAssertEqual(saved.note, "remember")
        XCTAssertEqual(saved.selectedText, "brown")
        XCTAssertEqual(store.bookmarks(for: "book", chapterIndex: 4).count, 0)
    }

    func testStalenessChecksBookAndChapter() throws {
        let selection = try XCTUnwrap(select(NSRange(location: 0, length: 3)))
        XCTAssertTrue(ReaderHighlightEditor.isCurrent(selection, bookID: "book", chapterIndex: 3))
        XCTAssertFalse(ReaderHighlightEditor.isCurrent(selection, bookID: "other", chapterIndex: 3))
        XCTAssertFalse(ReaderHighlightEditor.isCurrent(selection, bookID: "book", chapterIndex: 2))
    }

    func testPlaybackUsesTheWholeExistingHighlightNotThePartialSelection() throws {
        store.addBookmark(bookId: "book", chapterIndex: 3, chapterTitle: "Three",
                          startChar: 4, endChar: 19, selectedText: "quick brown fox")
        let partial = try XCTUnwrap(select(NSRange(location: 6, length: 2)))
        XCTAssertEqual(editor.playbackRange(for: partial, in: text), NSRange(location: 4, length: 15))
        let fresh = try XCTUnwrap(select(NSRange(location: 35, length: 4)))
        XCTAssertEqual(editor.playbackRange(for: fresh, in: text), NSRange(location: 35, length: 4))
    }
}
