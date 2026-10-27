import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ReaderInternalLinkTargetTests: XCTestCase {
    private func chapter(_ path: String, html: String, index: Int = 1) -> EbookFulltext.Chapter {
        .init(index: index, name: path, sourcePath: path, text: "Body", html: html, css: nil, charCount: nil, segments: nil)
    }
    private func link(_ target: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "epub-link"
        components.host = "open"
        components.queryItems = [.init(name: "target", value: target)]
        return try XCTUnwrap(components.url)
    }

    func testNestedNoteKeepsAllParagraphsAndFormatting() throws {
        let html = "<div id='note'><p>First <em>paragraph</em>.</p><div><p>Nested.</p></div><p>Last.</p></div><p>Outside.</p>"
        let result = try XCTUnwrap(EpubAnchorFragment.html(identifier: "note", in: html))
        XCTAssertTrue(result.contains("<em>paragraph</em>"))
        XCTAssertTrue(result.contains("Last."))
        XCTAssertFalse(result.contains("Outside."))
    }

    func testDuplicateMissingAndMalformedAnchorsFailClosed() {
        XCTAssertNil(EpubAnchorFragment.html(identifier: "n", in: "<p id='n'>One</p><p id='n'>Two</p>"))
        XCTAssertNil(EpubAnchorFragment.html(identifier: "n", in: "<p id='other'>Text</p>"))
        XCTAssertNil(EpubAnchorFragment.html(identifier: "n", in: "<p id='n'>Unclosed"))
    }

    func testEmptyAndNumberOnlyAnchorsPreviewTheReadableContainingBlock() {
        for body in ["<p><a id='n'></a>Note body.</p>", "<p><a id='n'>1</a> Note body.</p>"] {
            XCTAssertTrue(EpubAnchorFragment.html(identifier: "n", in: body)?.contains("Note body.") == true)
        }
    }

    func testStandaloneNamedAnchorUsesFollowingReadableBlock() {
        let result = EpubAnchorFragment.html(identifier: "n", in: "<a name='n'/><p>Following note.</p><p>Unrelated.</p>")
        XCTAssertTrue(result?.contains("Following note.") == true)
        XCTAssertFalse(result?.contains("Unrelated.") == true)
    }

    func testHTMLVoidTagsAndPortuguesePunctuationSurvive() {
        let result = EpubAnchorFragment.html(identifier: "nota", in: "<p id='nota'>Ação&nbsp;&mdash;<br>café.</p>")
        XCTAssertTrue(result?.contains("Ação") == true)
        XCTAssertTrue(result?.contains("café.") == true)
    }

    func testSameDocumentFragmentRetainsSourcePositionAndIdentifier() throws {
        let current = chapter("Text/Main.xhtml", html: "<p id='nota 1'>Ação.</p>", index: 9)
        let result = try XCTUnwrap(ReaderLinkResolver.internalTarget(for: try link("#nota%201"), currentChapter: current, chapters: [current]))
        XCTAssertEqual(result.chapterPosition, 0)
        XCTAssertEqual(result.fragment, "nota 1")
        XCTAssertTrue(result.html?.contains("Ação.") == true)
    }

    func testRelativeCrossChapterFragmentUsesTheResolvedSourcePath() throws {
        let current = chapter("OEBPS/Text/main.xhtml", html: "<p>Current</p>")
        let note = chapter("OEBPS/Notes/end.xhtml", html: "<aside id='n'><p>Destination.</p></aside>", index: 20)
        let result = try XCTUnwrap(ReaderLinkResolver.internalTarget(for: try link("../Notes/end.xhtml#n"), currentChapter: current, chapters: [current, note]))
        XCTAssertEqual(result.chapterPosition, 1)
        XCTAssertEqual(result.fragment, "n")
        XCTAssertTrue(result.html?.contains("Destination.") == true)
    }

    func testMissingFragmentCannotSilentlyBecomeChapterStart() throws {
        let current = chapter("main.xhtml", html: "<p id='present'>Body</p>")
        XCTAssertNil(ReaderLinkResolver.internalTarget(for: try link("#missing"), currentChapter: current, chapters: [current]))
    }

    func testArchivePathCaseAndDuplicateIdentityAreNotGuessed() throws {
        let current = chapter("Main.xhtml", html: "<p>Current</p>")
        XCTAssertNil(ReaderLinkResolver.internalTarget(for: try link("main.xhtml"), currentChapter: current, chapters: [current]))
        XCTAssertNil(ReaderLinkResolver.internalTarget(for: try link("#n"), currentChapter: current, chapters: [current, current]))
    }

    func testExternalOrUntrustedSchemeIsNotAnInternalDestination() throws {
        let current = chapter("main.xhtml", html: "<p>Current</p>")
        for url in ["https://example.com/main.xhtml", "javascript:alert(1)", "file:///main.xhtml"] {
            XCTAssertNil(ReaderLinkResolver.internalTarget(for: try XCTUnwrap(URL(string: url)), currentChapter: current, chapters: [current]))
        }
    }

    func testRenderedRangeHandlesWhitespaceAndUTF16WithoutSourceOffsets() {
        XCTAssertEqual(ReaderAnchorRange.uniqueRange(preview: " Ação café.\n", in: "📖\nAção\n\n café.\nEnd"), NSRange(location: 3, length: 12))
    }

    func testAmbiguousIncludingOverlappingRenderedTextCannotJump() {
        XCTAssertNil(ReaderAnchorRange.uniqueRange(preview: "Note", in: "Note. Another Note."))
        XCTAssertNil(ReaderAnchorRange.uniqueRange(preview: "aaa", in: "aaaa"))
        XCTAssertNil(ReaderAnchorRange.uniqueRange(preview: "missing", in: "Body"))
        XCTAssertNil(ReaderAnchorRange.uniqueRange(preview: " \n", in: "Body"))
    }

    func testExcessiveNestingIsRejected() {
        let html = String(repeating: "<div>", count: 150) + "<p id='n'>Note.</p>" + String(repeating: "</div>", count: 150)
        XCTAssertNil(EpubAnchorFragment.html(identifier: "n", in: html))
    }
}
