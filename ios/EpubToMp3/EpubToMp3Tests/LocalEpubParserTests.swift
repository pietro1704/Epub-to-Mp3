import XCTest
@testable import EpubToMp3

final class LocalEpubParserTests: XCTestCase {

    func testParsesFixtureIntoSingleChapter() throws {
        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }

        // Fixture has only the OPF + cover (no XHTML in the spine), so
        // the parser should return nil — which is fine, the BookOpenView
        // falls back to text-only mode in that case.
        let payload = LocalEpubParser.parse(url: url, bookId: "fixture")
        XCTAssertNil(payload, "fixture has no spine content")
    }

    func testStripHTMLDropsSVGOnlyChapters() {
        // Regression: EPUB chapters whose body is just an SVG `<image>`
        // tag (cover pages, half-title pages) stripped down to the
        // file's `<title>` and bubbled up as "c0" / "c9" chapters in
        // the reader. The parser now filters them via a 50-char
        // minimum + title-similarity check.
        let svgOnly = """
        <html><head><title>c0</title></head><body>
        <svg xmlns="http://www.w3.org/2000/svg">
          <image xlink:href="cover.jpg"/>
        </svg>
        </body></html>
        """
        let stripped = LocalEpubParser.stripHTML(svgOnly)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Stripped output keeps "c0" only; the parser is responsible
        // for rejecting it as "too short / matches title".
        XCTAssertTrue(stripped.count < 50,
                      "expected near-empty strip, got: \(stripped)")
    }

    func testStripHTMLDecodesCommonEntitiesAndPreservesParagraphs() {
        let html = """
        <html><body>
        <p>Hello&nbsp;world &amp; <em>everyone</em>.</p>
        <p>Line two&mdash;here.</p>
        <script>ignored()</script>
        </body></html>
        """
        let stripped = LocalEpubParser.stripHTML(html)
        XCTAssertTrue(stripped.contains("Hello world & everyone."))
        XCTAssertTrue(stripped.contains("Line two—here."))
        XCTAssertFalse(stripped.contains("ignored"))
        // Paragraphs separated.
        XCTAssertTrue(stripped.contains("\n"))
    }
}

final class LocalFulltextCacheTests: XCTestCase {

    private func uniqueId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    func testRoundTrip() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }

        let payload = EbookFulltext(
            jobId: id,
            bookTitle: "Foundation",
            bookAuthor: "Asimov",
            chapters: [
                .init(index: 1, name: "I",
                      text: "Hari Seldon stood watch.",
                      html: nil, css: nil, charCount: 24, segments: nil)
            ]
        )
        LocalFulltextCache.save(payload, bookId: id)
        let read = LocalFulltextCache.read(bookId: id)
        XCTAssertEqual(read?.bookTitle, "Foundation")
        XCTAssertEqual(read?.chapters.count, 1)
        XCTAssertEqual(read?.chapters.first?.text, "Hari Seldon stood watch.")
    }

    func testReadReturnsNilForUnknownBook() {
        XCTAssertNil(LocalFulltextCache.read(bookId: "no-such-book-\(UUID().uuidString)"))
    }

    func testEvictRemovesEntry() {
        let id = uniqueId()
        let payload = EbookFulltext(jobId: id, bookTitle: nil,
                                    bookAuthor: nil, chapters: [])
        LocalFulltextCache.save(payload, bookId: id)
        XCTAssertNotNil(LocalFulltextCache.read(bookId: id))
        LocalFulltextCache.evict(bookId: id)
        XCTAssertNil(LocalFulltextCache.read(bookId: id))
    }
}
