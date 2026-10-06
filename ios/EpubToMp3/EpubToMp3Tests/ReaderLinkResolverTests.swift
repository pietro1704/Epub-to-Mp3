import XCTest
@testable import EpubToMp3

final class ReaderLinkResolverTests: XCTestCase {
    private func chapter(
        index: Int,
        name: String,
        sourcePath: String,
        footnotes: [EbookFulltext.Footnote]? = nil
    ) -> EbookFulltext.Chapter {
        EbookFulltext.Chapter(
            index: index,
            name: name,
            sourcePath: sourcePath,
            text: "Chapter body.",
            html: "<p>Chapter body.</p>",
            css: nil,
            charCount: 13,
            segments: nil,
            footnotes: footnotes
        )
    }

    @MainActor
    func testResolvesRelativeEPUBLinkToItsChapter() throws {
        let contents = chapter(index: 1, name: "Contents", sourcePath: "OEBPS/text/toc.xhtml")
        let target = chapter(index: 2, name: "Chapter Five", sourcePath: "OEBPS/text/chapter-5.xhtml")
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "chapter-5.xhtml#section"))

        XCTAssertEqual(
            ReaderLinkResolver.destination(
                for: url,
                linkText: "Chapter Five",
                currentChapter: contents,
                chapters: [contents, target]
            ),
            .chapter(1)
        )
    }

    @MainActor
    func testResolvesLinkedFootnoteByReferenceMarker() throws {
        let note = EbookFulltext.Footnote(number: "*", text: "A footnote body.")
        let current = chapter(
            index: 1,
            name: "Chapter One",
            sourcePath: "OEBPS/text/chapter-1.xhtml",
            footnotes: [note]
        )
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "notes.xhtml#footnote_number_1"))

        XCTAssertEqual(
            ReaderLinkResolver.destination(
                for: url,
                linkText: "*",
                currentChapter: current,
                chapters: [current]
            ),
            .footnote(note)
        )
    }

    @MainActor
    func testResolvesSameDocumentFootnoteBeforeCurrentChapter() throws {
        let note = EbookFulltext.Footnote(number: "1", text: "Same-document footnote.")
        let current = chapter(
            index: 1,
            name: "Chapter One",
            sourcePath: "OEBPS/text/chapter-1.xhtml",
            footnotes: [note]
        )
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "#note1"))

        XCTAssertEqual(
            ReaderLinkResolver.destination(
                for: url,
                linkText: "1",
                currentChapter: current,
                chapters: [current]
            ),
            .footnote(note)
        )
    }

    @MainActor
    func testLeavesExternalURLsForTheSystem() throws {
        let current = chapter(index: 1, name: "Chapter One", sourcePath: "OEBPS/text/chapter-1.xhtml")
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "https://example.com/guide"))

        XCTAssertEqual(
            ReaderLinkResolver.destination(for: url, linkText: "Guide", currentChapter: current, chapters: [current]),
            .external(url)
        )
    }

    @MainActor
    func testDoesNotOpenAnUnresolvedArchivePath() throws {
        let current = chapter(index: 1, name: "Chapter One", sourcePath: "OEBPS/text/chapter-1.xhtml")
        let url = try XCTUnwrap(EpubHtmlRenderer.readerLinkURL(for: "missing.xhtml#target"))

        XCTAssertEqual(
            ReaderLinkResolver.destination(for: url, linkText: "Missing", currentChapter: current, chapters: [current]),
            .unresolved
        )
    }
}
