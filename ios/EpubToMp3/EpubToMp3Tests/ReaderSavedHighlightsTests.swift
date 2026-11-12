import XCTest
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import EpubToMp3

final class ReaderSavedHighlightsTests: XCTestCase {
    func testRemovingTheLastSavedHighlightRestoresOriginalBookBackground() {
        let source = NSAttributedString(string: "First selected text. Next passage.", attributes: [.backgroundColor: HighlightColor.blue.platformColor])
        let bookmark = mark(start: 6, end: 19, text: "selected text")
        let painted = ReaderSavedHighlights.repaint(source, highlights: [bookmark])
        XCTAssertNotNil(ReaderSavedHighlights.target(at: NSRange(location: 8, length: 3), highlights: [bookmark], in: painted))
        let removed = ReaderSavedHighlights.repaint(painted, highlights: [])
        XCTAssertEqual(removed, source)
        XCTAssertEqual(removed.string, source.string)
    }

    func testRemovalDoesNotChangeAnotherHighlightOrTextAndRangesStayBounded() {
        let source = NSAttributedString(string: "First selected text. Next passage.")
        let first = mark(start: 6, end: 19, text: "selected text")
        let second = mark(start: 21, end: 33, text: "Next passage")
        let painted = ReaderSavedHighlights.repaint(source, highlights: [first, second])
        let removed = ReaderSavedHighlights.repaint(painted, highlights: [second])
        XCTAssertNil(removed.attribute(.backgroundColor, at: 8, effectiveRange: nil))
        XCTAssertNotNil(removed.attribute(.backgroundColor, at: 23, effectiveRange: nil))
        XCTAssertEqual(ReaderSavedHighlights.target(at: NSRange(location: 23, length: 2),
            highlights: [second], in: removed)?.id, second.id)
        XCTAssertNil(ReaderSavedHighlights.target(at: NSRange(location: NSNotFound, length: 1), highlights: [second], in: removed))
        XCTAssertNil(ReaderSavedHighlights.target(at: NSRange(location: 23, length: Int.max), highlights: [second], in: removed))
    }

    func testNativeWordSelectionCanTargetAPartialHighlightInsideTheWord() {
        let source = NSAttributedString(string: "prefix highlighted suffix")
        let bookmark = mark(start: 9, end: 14, text: "ghlig")
        let word = (source.string as NSString).range(of: "highlighted")
        XCTAssertEqual(ReaderSavedHighlights.target(at: word, highlights: [bookmark], in: source)?.id, bookmark.id)
    }

    func testPlaybackOffsetUsesUnicodeScalarBoundariesInsteadOfUTF16Length() {
        let source = "😀 Text continues"
        XCTAssertEqual(ReaderSavedHighlights.playbackRatio(at: 3, in: source), 2.0 / Double(source.unicodeScalars.count))
        XCTAssertNil(ReaderSavedHighlights.playbackRatio(at: -1, in: source))
    }

    private func mark(start: Int, end: Int, text: String) -> Bookmark {
        Bookmark(id: UUID(), bookId: "book", chapterIndex: 0, chapterTitle: "Chapter",
            startChar: start, endChar: end, selectedText: text, note: nil, color: .yellow, createdAt: .distantPast)
    }
}
