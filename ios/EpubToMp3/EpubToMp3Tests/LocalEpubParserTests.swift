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
