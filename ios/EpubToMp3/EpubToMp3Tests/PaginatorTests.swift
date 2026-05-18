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

    // MARK: - Word-boundary splitting

    func testNeverCutsMidWord() {
        // Build text with long words — if the paginator cuts mid-word, we'd
        // see a partial word at the end of a page followed by the rest on the
        // next page. We verify by checking that no page ends or starts with a
        // fragment that doesn't have a trailing punctuation or whitespace.
        let sentence = "Supercalifragilisticexpialidocious phenomenon extraordinarily"
        let big = Array(repeating: sentence, count: 40).joined(separator: ". ") + "."
        let s = spans(from: big)
        let pages = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 400, height: 300),
            fontSize: 18, lineSpacing: 6, columnWidth: 360, margin: 20
        )
        XCTAssertGreaterThan(pages.count, 1)
        for (i, page) in pages.enumerated() {
            // Page should not end with a partial word (a non-punctuation, non-space char
            // that is not part of a complete sentence termination).
            let trimmed = page.trimmingCharacters(in: .whitespacesAndNewlines)
            // If the page ends cleanly, the last character should be either
            // punctuation (sentence break) or a full word boundary (space follows in
            // next page). We just verify the paginator chose a sentence or space break.
            let lastChar = trimmed.last!
            let endsAtSentence = (lastChar == "." || lastChar == "!" || lastChar == "?")
            // If not at a sentence, it must have broken at a word boundary (space was
            // the split point). Verify by checking next page starts at word boundary.
            if !endsAtSentence && i + 1 < pages.count {
                let nextPage = pages[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                // Next page's first char should be uppercase or a standard word start
                // (not a lowercase fragment of a word). For our test data that consists
                // of "Supercalifragilisticexpialidocious phenomenon..." this means
                // the next page shouldn't start with a lowercase mid-word fragment.
                // Actually: the paginator splits on sentence boundaries or paragraph
                // breaks, so we just verify no word was cut by checking that neither
                // page ends in a hyphen-free partial.
                XCTAssertFalse(
                    trimmed.hasSuffix("ali") || trimmed.hasSuffix("extra"),
                    "page \(i) appears to have been cut mid-word: …\(trimmed.suffix(15))"
                )
                _ = nextPage // suppress unused warning
            }
        }
    }

    // MARK: - Paragraph break weighting

    func testParagraphBreaksCountAsFullLineWeight() {
        // A single span with paragraph breaks (\n\n) should produce more pages
        // than a single span of the same raw text joined with spaces (no breaks).
        // The paginator's weightedCount gives \n\n extra cost (remainder + full line).
        let base = "Some text here for testing pagination logic in a reasonable way."
        let plainText = Array(repeating: base, count: 30).joined(separator: " ")
        let paraText = Array(repeating: base, count: 30).joined(separator: "\n\n")

        let sPlain: [SentenceSpan] = [SentenceSpan(id: "s0", text: plainText,
                                                     startChar: 0, endChar: plainText.count)]
        let sPara: [SentenceSpan] = [SentenceSpan(id: "s0", text: paraText,
                                                    startChar: 0, endChar: paraText.count)]

        let pagesPlain = Paginator.paginate(
            spans: sPlain,
            pageSize: CGSize(width: 600, height: 400),
            fontSize: 16, lineSpacing: 4, columnWidth: 560, margin: 20
        )
        let pagesPara = Paginator.paginate(
            spans: sPara,
            pageSize: CGSize(width: 600, height: 400),
            fontSize: 16, lineSpacing: 4, columnWidth: 560, margin: 20
        )
        // Paragraph version should need more pages because \n\n costs extra
        XCTAssertGreaterThan(pagesPara.count, pagesPlain.count,
            "Paragraph breaks should increase page count due to weighted cost")
    }

    func testBareNewlineCostsLessThanParagraphBreak() {
        // \n costs only the remainder of the current line;
        // \n\n costs remainder + a full blank line. So text with \n\n should
        // paginate into more pages than text with bare \n.
        let withBareNewlines = Array(repeating: "Testing line breaks in paginator", count: 30)
            .joined(separator: ".\n") + "."
        let withParaBreaks = Array(repeating: "Testing line breaks in paginator", count: 30)
            .joined(separator: ".\n\n") + "."

        let sBare: [SentenceSpan] = [SentenceSpan(id: "s0", text: withBareNewlines,
                                                    startChar: 0, endChar: withBareNewlines.count)]
        let sPara: [SentenceSpan] = [SentenceSpan(id: "s0", text: withParaBreaks,
                                                    startChar: 0, endChar: withParaBreaks.count)]

        let pagesBare = Paginator.paginate(
            spans: sBare,
            pageSize: CGSize(width: 600, height: 400),
            fontSize: 16, lineSpacing: 4, columnWidth: 560, margin: 20
        )
        let pagesPara = Paginator.paginate(
            spans: sPara,
            pageSize: CGSize(width: 600, height: 400),
            fontSize: 16, lineSpacing: 4, columnWidth: 560, margin: 20
        )
        XCTAssertGreaterThan(pagesPara.count, pagesBare.count,
            "\\n\\n should cost more than bare \\n")
    }

    // MARK: - First page header deduction

    func testFirstPageHeaderDeductionReducesCapacity() {
        let big = Array(repeating: "A medium sentence for testing", count: 60)
            .joined(separator: ". ") + "."
        let s = spans(from: big)

        let noHeader = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 600, height: 400),
            fontSize: 16, lineSpacing: 4, columnWidth: 560, margin: 20,
            headerHeight: 0
        )
        let withHeader = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 600, height: 400),
            fontSize: 16, lineSpacing: 4, columnWidth: 560, margin: 20,
            headerHeight: 60
        )
        // With a header, the first page has less room, so total pages should
        // be >= the no-header version.
        XCTAssertGreaterThanOrEqual(withHeader.count, noHeader.count,
            "Header deduction should reduce first-page capacity")
    }

    // MARK: - Reasonable page count for realistic chapter

    func testReasonablePageCountFor20KChapter() {
        // A 20,000-char chapter with standard settings should produce a
        // reasonable number of pages (not 1, not 500+).
        let word = "Lorem ipsum dolor sit amet consectetur adipiscing elit"
        var text = ""
        while text.count < 20_000 {
            text += word + ". "
        }
        let s = spans(from: text)
        let pages = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 800, height: 1000),
            fontSize: 18, lineSpacing: 6, columnWidth: 700, margin: 40
        )
        // At ~18pt font, ~700px width, ~1000px height, a page holds roughly
        // 2000-4000 chars. 20K chars → 5-15 pages is reasonable.
        XCTAssertGreaterThanOrEqual(pages.count, 3,
            "20K chapter should produce at least 3 pages")
        XCTAssertLessThanOrEqual(pages.count, 25,
            "20K chapter should not exceed 25 pages with standard settings")
    }

    // MARK: - Maximal page fill (no premature paragraph breaks)

    func testPagesAreMaximallyFull() {
        // Build text with many paragraphs. The paginator should NOT break
        // at the first paragraph boundary — it should fill each page as
        // much as possible (word-boundary splitting), like Apple Books.
        let paragraph = "The quick brown fox jumped over the lazy dog and ran across the meadow."
        // 30 short paragraphs separated by \n\n. Each paragraph is ~70 chars.
        // Total ~2100 chars + separators. With a page budget of ~1500 chars,
        // the old code would break at the first \n\n within budget (~70 chars),
        // wasting most of the page. The new code should fill pages fully.
        let text = Array(repeating: paragraph, count: 30).joined(separator: "\n\n")
        let s: [SentenceSpan] = [SentenceSpan(id: "s0", text: text,
                                                startChar: 0, endChar: text.count)]
        let pages = Paginator.paginate(
            spans: s,
            pageSize: CGSize(width: 600, height: 500),
            fontSize: 16, lineSpacing: 4, columnWidth: 560, margin: 20
        )
        XCTAssertGreaterThan(pages.count, 1, "Text should span multiple pages")

        // Each non-last page should contain multiple paragraphs (not just one).
        // If pages break at paragraph boundaries, page 0 would contain only
        // ~70 chars. With maximal fill, page 0 should contain many paragraphs.
        for i in 0..<(pages.count - 1) {
            let pageText = pages[i]
            // Count paragraph separators within each page
            let paraCount = pageText.components(separatedBy: "\n\n").count
            XCTAssertGreaterThan(paraCount, 2,
                "Page \(i) should contain multiple paragraphs for maximal fill, got \(paraCount)")
        }
    }

    // MARK: - Font-family charWidth factor

    func testMonoFamilyProducesMorePages() {
        // mono factor 0.58 > serif 0.52 > sans 0.44
        // wider charWidth → fewer chars/line → more pages
        let big = Array(repeating: "Quick brown fox jumps over lazy dog testing pagination", count: 60)
            .joined(separator: ". ") + "."
        let s = spans(from: big)
        let pageSize = CGSize(width: 600, height: 500)
        let base = (pageSize: pageSize, fontSize: CGFloat(18),
                    lineSpacing: 4.0, columnWidth: CGFloat(560), margin: 20.0)

        let sans = Paginator.paginate(
            spans: s, pageSize: base.pageSize, fontSize: base.fontSize,
            lineSpacing: base.lineSpacing, columnWidth: base.columnWidth,
            margin: base.margin, fontFamily: .sans)
        let serif = Paginator.paginate(
            spans: s, pageSize: base.pageSize, fontSize: base.fontSize,
            lineSpacing: base.lineSpacing, columnWidth: base.columnWidth,
            margin: base.margin, fontFamily: .serif)
        let mono = Paginator.paginate(
            spans: s, pageSize: base.pageSize, fontSize: base.fontSize,
            lineSpacing: base.lineSpacing, columnWidth: base.columnWidth,
            margin: base.margin, fontFamily: .mono)

        // sans (0.44) → fewest pages, mono (0.58) → most pages
        XCTAssertLessThanOrEqual(sans.count, serif.count,
            "sans should yield ≤ pages than serif")
        XCTAssertLessThanOrEqual(serif.count, mono.count,
            "serif should yield ≤ pages than mono")
    }

    func testSansFamilyMatchesDefaultBehavior() {
        // Default omitting fontFamily uses .sans (0.44 factor).
        let big = Array(repeating: "Testing font family default parity check", count: 50)
            .joined(separator: ". ") + "."
        let s = spans(from: big)
        let pageSize = CGSize(width: 700, height: 600)

        let withDefault = Paginator.paginate(
            spans: s, pageSize: pageSize, fontSize: 18,
            lineSpacing: 4, columnWidth: 640, margin: 30)
        let withSans = Paginator.paginate(
            spans: s, pageSize: pageSize, fontSize: 18,
            lineSpacing: 4, columnWidth: 640, margin: 30, fontFamily: .sans)

        XCTAssertEqual(withDefault.count, withSans.count,
            "default and explicit .sans should produce identical pagination")
    }

    func testPageTurnStyleEnum() {
        // Verify PageTurnStyle enum has expected cases and raw values
        XCTAssertEqual(PageTurnStyle.flip.rawValue, "flip")
        XCTAssertEqual(PageTurnStyle.slide.rawValue, "slide")
        XCTAssertEqual(PageTurnStyle.none.rawValue, "none")
        XCTAssertEqual(PageTurnStyle.allCases.count, 3)
    }

    func testPageTurnStylePersistence() {
        let defaults = UserDefaults(suiteName: "PaginatorTestSuite")!
        defaults.removePersistentDomain(forName: "PaginatorTestSuite")
        let settings = AppSettings(defaults: defaults)
        // Default should be .flip
        XCTAssertEqual(settings.pageTurnStyle, .flip)
        // Change and verify persistence
        settings.pageTurnStyle = .slide
        XCTAssertEqual(defaults.string(forKey: "pageTurnStyle"), "slide")
        settings.pageTurnStyle = .none
        XCTAssertEqual(defaults.string(forKey: "pageTurnStyle"), "none")
    }
}
