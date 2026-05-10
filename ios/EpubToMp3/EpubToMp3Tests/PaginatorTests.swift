import XCTest
import SwiftUI
@testable import EpubToMp3

/// Pure-logic tests for `Paginator.paginate(...)`. We don't mount a
/// SwiftUI view tree — the paginator is a static helper that walks
/// the sentence list, so it tests cleanly without UIKit/AppKit.
final class PaginatorTests: XCTestCase {

    private func spans(from text: String) -> [SentenceSpan] {
        // Split on every full stop so each "sentence" is a clean
        // paginator boundary. Mirrors what `EbookFulltext.Chapter.splitSentences`
        // would emit for short text.
        let pieces = text.components(separatedBy: ". ")
        return pieces.enumerated().map { i, p in
            SentenceSpan(id: "s\(i)", text: p + ".",
                         startChar: 0, endChar: p.count + 1)
        }
    }

    func testEmptyInputReturnsNoPages() {
        XCTAssertTrue(Paginator.paginate(
            spans: [],
            pageSize: CGSize(width: 800, height: 600),
            fontSize: 20, lineSpacing: 6, columnWidth: 720, margin: 24
        ).isEmpty)
    }

    func testShortChapterFitsInOnePage() {
        let s = spans(from: "Just a short opener. Two sentences only")
        let pages = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 800, height: 600),
            fontSize: 20, lineSpacing: 6, columnWidth: 720, margin: 24
        )
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(pages[0].contains("Just a short opener"))
        XCTAssertTrue(pages[0].contains("Two sentences"))
    }

    func testLongChapterSplitsAtSentenceBoundaries() {
        let sentence = "The quick brown fox jumped over the lazy dog and ran fast"
        let big = Array(repeating: sentence, count: 80).joined(separator: ". ") + "."
        let s = spans(from: big)
        let pages = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 600, height: 400),
            fontSize: 20, lineSpacing: 6, columnWidth: 600, margin: 24
        )
        XCTAssertGreaterThan(pages.count, 1)
        // Every page must end with a sentence terminator (we split on
        // sentence boundaries).
        for (i, page) in pages.enumerated() {
            let last = page.last
            XCTAssertTrue(last == "." || last == "?" || last == "!",
                          "page \(i) does not end at a sentence boundary: \(page.suffix(20))")
        }
    }

    func testSmallerFontSizeYieldsFewerPages() {
        let big = Array(repeating: "Hello world this is a sentence", count: 60)
            .joined(separator: ". ") + "."
        let s = spans(from: big)
        let small = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 800, height: 600),
            fontSize: 14, lineSpacing: 4, columnWidth: 720, margin: 24
        )
        let large = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 800, height: 600),
            fontSize: 28, lineSpacing: 8, columnWidth: 720, margin: 24
        )
        XCTAssertLessThanOrEqual(small.count, large.count)
    }
}
