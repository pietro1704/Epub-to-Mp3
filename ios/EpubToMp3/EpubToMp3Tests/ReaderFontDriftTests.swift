import XCTest
@testable import EpubToMp3

/// Regression: changing the reader font / size / spacing / margin
/// repaginates the chapter. Without translating `currentPage` through
/// the saved cumulative text offset, the reading position drifts by a
/// page. `ReaderView.syncPageToTextOffset(in:)` re-derives the page
/// from `textOffsetAtCurrentPage` on every debounced settings change.
///
/// These tests mirror `ReaderView.findPage(containing:in:)` (a private
/// helper) against `Paginator.paginate` output to lock the contract:
/// offset-based translation preserves position across a repagination,
/// whereas keeping the raw index does not.
@MainActor
final class ReaderFontDriftTests: XCTestCase {

    private func makeSpans() -> [SentenceSpan] {
        let chapter = EbookFulltext.Chapter(
            index: 1,
            name: "Chapter 1",
            text: String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 240),
            html: nil,
            css: nil,
            charCount: 0,
            segments: nil
        )
        return chapter.splitSentences()
    }

    /// Mirror of `ReaderView.findPage(containing:in:)`.
    private func findPage(offset: Int, in pages: [String]) -> Int {
        guard !pages.isEmpty else { return 0 }
        var cumulative = 0
        for (i, page) in pages.enumerated() {
            cumulative += page.count
            if cumulative > offset { return i }
        }
        return pages.count - 1
    }

    private func cumulativeOffset(upToPage index: Int, in pages: [String]) -> Int {
        guard index > 0 else { return 0 }
        return pages.prefix(index).reduce(0) { $0 + $1.count }
    }

    /// Enlarging the font produces more pages; the raw index now points
    /// at the wrong text. Translating through the saved offset lands at
    /// least as close to the original reading position as the naive
    /// index — usually exact.
    func testOffsetTranslationBeatsNaiveIndexOnFontEnlarge() {
        let spans = makeSpans()
        let size = CGSize(width: 390, height: 600)
        let pagesSmall = Paginator.paginate(
            spans: spans, pageSize: size,
            fontSize: 15, lineSpacing: 4, columnWidth: 330, margin: 24
        )
        let pagesLarge = Paginator.paginate(
            spans: spans, pageSize: size,
            fontSize: 30, lineSpacing: 4, columnWidth: 330, margin: 24
        )
        XCTAssertGreaterThan(pagesSmall.count, 4, "need a multi-page chapter")
        XCTAssertGreaterThan(pagesLarge.count, pagesSmall.count,
                             "a larger font must yield more pages")

        let readingPage = pagesSmall.count / 2
        let offset = cumulativeOffset(upToPage: readingPage, in: pagesSmall)

        // Naive path: keep the same page index after repagination.
        let naiveIndex = min(readingPage, pagesLarge.count - 1)
        let naiveOffset = cumulativeOffset(upToPage: naiveIndex, in: pagesLarge)

        // Fix path: translate the index through the saved text offset.
        let translated = findPage(offset: offset, in: pagesLarge)
        let translatedOffset = cumulativeOffset(upToPage: translated, in: pagesLarge)

        // The translated page must start at or before the saved offset.
        XCTAssertLessThanOrEqual(translatedOffset, offset,
            "translated page must contain the saved offset")
        // ...and land at least as close to it as the naive index.
        XCTAssertLessThanOrEqual(abs(translatedOffset - offset),
                                 abs(naiveOffset - offset),
            "offset translation must not drift further than the raw index")
    }

    /// Translation is idempotent when pagination is unchanged: the same
    /// offset round-trips back to the same page.
    func testOffsetTranslationIdempotentWhenPaginationUnchanged() {
        let spans = makeSpans()
        let size = CGSize(width: 390, height: 600)
        let pages = Paginator.paginate(
            spans: spans, pageSize: size,
            fontSize: 18, lineSpacing: 4, columnWidth: 330, margin: 24
        )
        XCTAssertGreaterThan(pages.count, 3)
        let page = 3
        let offset = cumulativeOffset(upToPage: page, in: pages)
        XCTAssertEqual(findPage(offset: offset, in: pages), page,
            "same pagination must round-trip the page index")
    }
}
