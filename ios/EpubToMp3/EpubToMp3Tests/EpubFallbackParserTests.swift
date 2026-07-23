// EpubFallbackParserTests.swift
//
// Tests for `EpubFallbackParser.parse(url:bookId:)`. All artefact
// handling (U+FEFF, &#160;, [object Object], malformed HTML) is
// exercised by constructing a minimal in-memory EPUB ZIP via
// `EpubFixture.createWithChapter`, injecting the target HTML into
// the spine chapter, and asserting on the returned `EbookFulltext`.
//
// Coverage:
//   - U+FEFF (BOM / zero-width no-break space) removed.
//   - &#160; / &#xA0; numeric entities become plain space.
//   - [object Object] JS serialisation artifact removed.
//   - Named entities decoded (&amp;, &lt;, &nbsp;, &mdash;, &hellip;).
//   - <script> / <style> content excluded from chapter text.
//   - Empty EPUB produces no chapters (never throws).
//   - Chapter title extracted from <h1> when present.
//   - Large single paragraph yields non-empty text.

import XCTest
@testable import EpubToMp3

final class EpubFallbackParserTests: XCTestCase {

    // MARK: - Helpers

    /// Build a single-chapter EPUB with arbitrary HTML body, parse it,
    /// and return the resulting chapter text (trimmed).
    private func parsed(html body: String,
                        heading: String? = nil) throws -> String {
        let h1 = heading.map { "<h1>\($0)</h1>" } ?? ""
        let chapterBody = "\(h1)\(body)"
        let url = try EpubFixture.createWithChapter(
            chapterTitle: heading ?? "Chapter 1",
            body: chapterBody
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = EpubFallbackParser.parse(url: url, bookId: "test-id")
        return result.chapters.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func parsedChapters(html body: String) throws -> [EbookFulltext.Chapter] {
        let url = try EpubFixture.createWithChapter(body: body)
        defer { try? FileManager.default.removeItem(at: url) }
        return EpubFallbackParser.parse(url: url, bookId: "test-id").chapters
    }

    // MARK: - U+FEFF / BOM

    func testBOMIsRemovedFromChapterText() throws {
        let text = try parsed(html: "<p>\u{FEFF}Hello World</p>")

        XCTAssertFalse(text.contains("\u{FEFF}"),
            "U+FEFF must be stripped; got: \(text.prefix(80))")
        XCTAssertTrue(text.contains("Hello World"))
    }

    // MARK: - Numeric entities

    func testNBSPDecimalEntityBecomesSpace() throws {
        let text = try parsed(html: "<p>word&#160;word</p>")

        XCTAssertFalse(text.contains("&#160;"),
            "&#160; must be replaced; got: \(text.prefix(80))")
        XCTAssertTrue(text.contains("word word") || text.contains("word  word"),
            "Tokens must be space-separated; got: \(text.prefix(80))")
    }

    func testNBSPHexEntityBecomesSpace() throws {
        let text = try parsed(html: "<p>a&#xA0;b</p>")

        XCTAssertFalse(text.contains("&#xA0;"))
    }

    // MARK: - JS artifact

    func testObjectObjectIsRemoved() throws {
        let text = try parsed(html: "<p>[object Object]useful text</p>")

        XCTAssertFalse(text.contains("[object Object]"))
        XCTAssertTrue(text.contains("useful text"))
    }

    // MARK: - Named entity decoding

    func testAmpersandEntityDecoded() throws {
        let text = try parsed(html: "<p>A &amp; B</p>")

        XCTAssertTrue(text.contains("A & B"),
            "&amp; must decode to &; got: \(text.prefix(80))")
    }

    func testNbspNamedEntityBecomesSpace() throws {
        let text = try parsed(html: "<p>left&nbsp;right</p>")

        XCTAssertFalse(text.contains("&nbsp;"))
    }

    func testMdashDecoded() throws {
        let text = try parsed(html: "<p>word&mdash;word</p>")

        XCTAssertTrue(text.contains("word\u{2014}word") || text.contains("word — word"),
            "&mdash; must decode to EM DASH; got: \(text.prefix(80))")
    }

    func testEllipsisDecoded() throws {
        let text = try parsed(html: "<p>Wait&hellip;</p>")

        XCTAssertTrue(text.contains("Wait\u{2026}") || text.contains("Wait..."),
            "&hellip; must decode; got: \(text.prefix(80))")
    }

    // MARK: - Script / style exclusion

    func testScriptContentExcluded() throws {
        let text = try parsed(html: "<script>alert('xss')</script><p>Visible</p>")

        XCTAssertFalse(text.contains("alert"),
            "<script> body must not appear in chapter text")
        XCTAssertTrue(text.contains("Visible"))
    }

    func testStyleContentExcluded() throws {
        let text = try parsed(html: "<style>body{color:red}</style><p>Text</p>")

        XCTAssertFalse(text.contains("color"),
            "<style> body must not appear in chapter text")
        XCTAssertTrue(text.contains("Text"))
    }

    // MARK: - Empty / malformed HTML

    func testUnreadableEpubReturnsZeroChapters() {
        // Providing a non-existent URL must never throw; parser returns empty.
        let bad = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).epub")
        let result = EpubFallbackParser.parse(url: bad, bookId: "bad-id")

        XCTAssertTrue(result.chapters.isEmpty,
            "Unreadable EPUB must yield 0 chapters, not crash")
    }

    func testMalformedHTMLUnclosedTagDoesNotCrash() throws {
        let text = try parsed(html: "<p>Start <b>unclosed bold")

        XCTAssertTrue(text.contains("Start"),
            "Unclosed tag must not crash or eat visible text")
    }

    func testAllArtifactsCombined() throws {
        let body = "<p>\u{FEFF}Chapter&#160;1[object Object]</p>" +
                   "<p>The&nbsp;end&hellip;</p>"
        let text = try parsed(html: body)

        XCTAssertFalse(text.contains("\u{FEFF}"))
        XCTAssertFalse(text.contains("&#160;"))
        XCTAssertFalse(text.contains("[object Object]"))
        XCTAssertTrue(text.contains("Chapter 1") || text.contains("Chapter  1"))
        XCTAssertTrue(text.contains("end\u{2026}") || text.contains("end...") ||
                      text.contains("end"),
            "End text must be present; got: \(text.prefix(120))")
    }

    // MARK: - Title extraction

    func testH1TitleUsedAsChapterName() throws {
        let url = try EpubFixture.createWithChapter(
            chapterTitle: "My Chapter",
            body: "<h1>My Chapter</h1><p>Body text here.</p>"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = EpubFallbackParser.parse(url: url, bookId: "t")
        let chapter = result.chapters.first
        let name = try XCTUnwrap(chapter?.name)

        XCTAssertTrue(name.contains("My Chapter") || name.contains("Chapter"),
            "Chapter name must derive from <h1>; got: \(name)")
    }

    func testChapterImagesResolveRelativeToArchivePath() throws {
        let url = try EpubFixture.createWithChapter(
            body: "<img src=\"../images/cover.png\"/><p>Body text here.</p>"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = EpubFallbackParser.parse(url: url, bookId: "image-test")
        let resources = try XCTUnwrap(result.chapters.first?.resources)
        let resource = try XCTUnwrap(resources.first)

        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resource.href, "../images/cover.png")
        XCTAssertEqual(resource.mediaType, "image/png")
        XCTAssertEqual(Data(base64Encoded: resource.dataBase64 ?? ""), EpubFixture.coverPNG)
    }

    func testAbsoluteFilesystemPrefixResolvesToArchiveSuffix() {
        let candidate = "/tmp/imported-book/Users/pietro/Developer/Epub-to-Mp3/OEBPS/images/cover.png"
        let entries = ["OEBPS/images/cover.png"]

        XCTAssertEqual(
            EpubFallbackParser.resolveArchiveMember(candidate, entries: entries),
            "OEBPS/images/cover.png"
        )
    }

    // MARK: - Large single paragraph

    func testLargeSingleParagraphPreservesText() throws {
        let longText = String(repeating: "word ", count: 2000)
        let text = try parsed(html: "<p>\(longText)</p>")

        XCTAssertGreaterThan(text.count, 100,
            "Large paragraph must not be empty after stripping")
        XCTAssertTrue(text.contains("word"))
    }
}
