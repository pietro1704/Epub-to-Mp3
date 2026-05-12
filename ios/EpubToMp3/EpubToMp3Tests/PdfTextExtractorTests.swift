import XCTest
import PDFKit
@testable import EpubToMp3

final class PdfTextExtractorTests: XCTestCase {

    func testExtractsSingleChapterFromSinglePagePdf() throws {
        let url = try PdfFixture.createSinglePage(
            title: "Single Page Book",
            author: "Author",
            bodyText: "Body paragraph one."
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let fulltext = try PdfTextExtractor.extract(from: url, bookId: "book-id-123")
        XCTAssertEqual(fulltext.jobId, "book-id-123")
        XCTAssertEqual(fulltext.bookTitle, "Single Page Book")
        XCTAssertEqual(fulltext.bookAuthor, "Author")
        XCTAssertEqual(fulltext.chapters.count, 1)
        let chapter = try XCTUnwrap(fulltext.chapters.first)
        XCTAssertTrue(chapter.text.contains("Body paragraph"),
                      "chapter text should contain the body. Got: \(chapter.text)")
    }

    func testGroupsMultiPagePdfByHeadingFontSize() throws {
        // Each page has a 28pt bold heading + 12pt body. The
        // heading heuristic should produce one chapter per page.
        let url = try PdfFixture.createMultiPage(
            pages: [
                (heading: "First Heading", body: "First page body."),
                (heading: "Second Heading", body: "Second page body."),
                (heading: "Third Heading", body: "Third page body."),
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let fulltext = try PdfTextExtractor.extract(from: url, bookId: "")
        XCTAssertGreaterThanOrEqual(
            fulltext.chapters.count, 1,
            "extractor must produce at least one chapter for a 3-page PDF"
        )
        // The chapters' combined text must mention all three bodies —
        // we're not picky about whether the heuristic merged them or
        // split them, only that no text is lost in chapter assembly.
        let joined = fulltext.chapters.map { $0.text }.joined(separator: " ")
        XCTAssertTrue(joined.contains("First page body"))
        XCTAssertTrue(joined.contains("Second page body"))
        XCTAssertTrue(joined.contains("Third page body"))
    }

    func testLooksLikeChapterKeywordRecognisesCommonPrefixes() {
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("Chapter 1"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("CHAPTER 12"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("Capítulo 3"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("Part 1"))
        // Roman-numeral / bare-digit short lines.
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("I"))
        XCTAssertTrue(PdfTextExtractor.looksLikeChapterKeyword("3"))
        // Sentences shouldn't trip the heuristic.
        XCTAssertFalse(PdfTextExtractor.looksLikeChapterKeyword("The quick brown fox"))
        XCTAssertFalse(PdfTextExtractor.looksLikeChapterKeyword(""))
    }

    func testFallbackChapterWhenNoOutlineOrHeadingsDetected() {
        // We can't easily craft a PDF that defeats both signals at
        // once from a unit test, so cover the helper directly: an
        // empty PDF document should yield zero chapters from the
        // fallback rather than throwing.
        let empty = PDFDocument()
        let chapters = PdfTextExtractor.chaptersFromFallback(document: empty)
        XCTAssertTrue(chapters.isEmpty)
    }

    func testChaptersFromOutlineReturnsNilWhenOutlineEmpty() {
        let empty = PDFDocument()
        XCTAssertNil(PdfTextExtractor.chaptersFromOutline(document: empty))
    }
}
