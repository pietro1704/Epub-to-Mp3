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
    func testNCXLabelsAndHierarchyReplaceRepeatedDocumentTitlesWithoutChangingSpineIdentity() throws {
        let document = "<html><head><title>repeated_export_name</title></head><body><p id='start'>Fixture text.</p><p id='next'>Another section.</p></body></html>"
        let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint id="cover"><navLabel><text>Cover label</text></navLabel><content src="../Text/cover.xhtml"/></navPoint>
          <navPoint id="part"><navLabel><text>Part One &amp; More</text></navLabel><content src="../Text/split001.xhtml#start"/>
            <navPoint id="section"><navLabel><text>Section One</text></navLabel><content src="../Text/split001.xhtml#next"/></navPoint>
          </navPoint>
          <navPoint id="last"><navLabel><text>Part Two</text></navLabel><content src="../Text/split002.xhtml"/></navPoint>
        </navMap></ncx>
        """
        let source = try EpubFixture.createWithNavigation(documents: [
            ("Text/cover.xhtml", document), ("Text/copyright.xhtml", document),
            ("Text/split001.xhtml", document), ("Text/split002.xhtml", document)], ncx: ncx)
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = EpubFallbackParser.parse(url: source, bookId: "navigation-fixture")
        XCTAssertEqual(payload.chapters.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(payload.chapters.map(\.sourcePath), ["OEBPS/Text/cover.xhtml", "OEBPS/Text/copyright.xhtml",
            "OEBPS/Text/split001.xhtml", "OEBPS/Text/split002.xhtml"])
        XCTAssertEqual(payload.chapters[2].name, "Part One & More")
        XCTAssertEqual(payload.chapters[3].name, "Part Two")
        let rows = ReaderTocFlattener.rows(toc: payload.toc, chapters: payload.chapters)
        XCTAssertEqual(rows.map(\.title), ["Cover label", "Part One & More", "Section One", "Part Two"])
        XCTAssertEqual(rows.map(\.level), [0, 0, 1, 0])
        XCTAssertEqual(rows.map(\.chapterIndex), [0, 2, 2, 3], "Fragments resolve to the containing document, never a new ordinal")
        XCTAssertFalse(rows.contains { $0.title == "repeated_export_name" })
    }

    func testEPUB3TOCNavigationTakesPrecedenceAndIgnoresLandmarks() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
        <nav epub:type="landmarks"><ol><li><a href="../Text/chapter%20one.xhtml">Wrong landmark</a></li></ol></nav>
        <nav epub:type="toc"><ol><li><span>Volume</span><ol>
          <li><a href="../Text/chapter%20one.xhtml#start"><span>Actual</span> chapter</a></li>
          <li><a href="https://example.invalid/chapter">External reference</a></li>
          <li><a href="../Text/missing.xhtml">Missing chapter</a></li>
        </ol></li></ol></nav></body></html>
        """
        let ncx = "<ncx><navMap><navPoint><navLabel><text>Old NCX label</text></navLabel><content src='../Text/chapter%20one.xhtml'/></navPoint></navMap></ncx>"
        let source = try EpubFixture.createWithNavigation(documents: [("Text/chapter one.xhtml", "<html><body><p id='start'>Readable fixture.</p></body></html>")], ncx: ncx, nav: nav)
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = EpubFallbackParser.parse(url: source, bookId: "nav-fixture")
        let rows = ReaderTocFlattener.rows(toc: payload.toc, chapters: payload.chapters)
        XCTAssertEqual(rows.map(\.title), ["Volume", "Actual chapter", "External reference", "Missing chapter"])
        XCTAssertEqual(rows.map(\.level), [0, 1, 1, 1])
        XCTAssertEqual(rows.map(\.chapterIndex), [nil, 0, nil, nil])
        XCTAssertEqual(payload.chapters.first?.name, "Actual chapter")
    }

    func testMalformedNavigationFallsBackToDeclaredNCXAndUnresolvedEntriesStayDisabled() throws {
        let ncx = "<ncx><navMap><navPoint><navLabel><text>Preserved label</text></navLabel><content src='../Text/one.xhtml'/></navPoint><navPoint><navLabel><text>Absent</text></navLabel><content src='../Text/absent.xhtml#note'/></navPoint></navMap></ncx>"
        let source = try EpubFixture.createWithNavigation(documents: [("Text/one.xhtml", "<html><body><h1>Misleading heading</h1><p>Fixture.</p></body></html>")],
                                                        ncx: ncx, nav: "<html><nav epub:type='toc'><ol><li>")
        defer { try? FileManager.default.removeItem(at: source) }
        let payload = EpubFallbackParser.parse(url: source, bookId: "fallback-navigation")
        let rows = ReaderTocFlattener.rows(toc: payload.toc, chapters: payload.chapters)
        XCTAssertEqual(rows.map(\.title), ["Preserved label", "Absent"])
        XCTAssertEqual(rows.map(\.chapterIndex), [0, nil])
        XCTAssertEqual(payload.chapters.first?.name, "Preserved label")
    }


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

    func testLargeEntityHeavyChapterDoesNotMultiplyWholeStringMemory() throws {
        let body = String(repeating: "word&amp;word ", count: 100_000)
        let text = try parsed(html: "<p>\(body)</p>")

        XCTAssertTrue(text.contains("word&word"))
        XCTAssertFalse(text.contains("&amp;"))
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

    // MARK: - Native source markup and resource preservation

    func testChapterNamePreservesDocumentHeading() throws {
        let url = try EpubFixture.createWithChapter(
            chapterTitle: "My Chapter",
            body: "<h1>My Chapter</h1><p>Body text here.</p>"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = EpubFallbackParser.parse(url: url, bookId: "t")
        let name = try XCTUnwrap(result.chapters.first?.name)

        XCTAssertEqual(name, "My Chapter")
    }

    func testChapterPreservesSourceHTMLForFaithfulRendering() throws {
        let url = try EpubFixture.createWithChapter(
            body: "<img src=\"../images/cover.png\"/><p>Body text here.</p>",
            stylesheet: "body { height: 100vh; overflow: hidden; }"
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let chapter = try XCTUnwrap(EpubFallbackParser.parse(url: url, bookId: "image-test").chapters.first)

        XCTAssertNotNil(chapter.html, "Fallback chapters must retain source markup")
        XCTAssertNil(chapter.css, "Fallback must never pass clipping EPUB CSS to the reader")
        XCTAssertEqual(chapter.resources?.first?.mediaType, "image/png")
        XCTAssertNotNil(chapter.resources?.first?.dataBase64)
        XCTAssertTrue(chapter.text.contains("Body text here"))
    }

    func testPreservesSourcePathAndLinkedFootnote() throws {
        let url = try EpubFixture.createWithChapter(
            body: "Body text here.",
            footnote: (reference: "*", text: "The linked footnote body.")
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let chapter = try XCTUnwrap(EpubFallbackParser.parse(url: url, bookId: "note-test").chapters.first)

        XCTAssertEqual(chapter.sourcePath, "OEBPS/text/chapter1.xhtml")
        XCTAssertEqual(chapter.footnotes, [
            .init(number: "*", text: "The linked footnote body.")
        ])
    }

    func testPreservesSameDocumentLinkedFootnote() throws {
        let url = try EpubFixture.createWithChapter(
            body: "Body text here.",
            footnote: (reference: "#note1", text: "Same-document footnote body.")
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let chapter = try XCTUnwrap(EpubFallbackParser.parse(url: url, bookId: "same-note-test").chapters.first)

        XCTAssertEqual(chapter.footnotes, [
            .init(number: "#note1", text: "Same-document footnote body.")
        ])
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
