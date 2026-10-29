import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class EpubFontAliasesTests: XCTestCase {
    func testRegisteredBookFontAliasResolvesWithoutDroppingFallbacks() {
        let css = "@font-face {font-family:'Book Serif';src:url('../fonts/book.ttf')} p{font-family:'Book Serif', Georgia, serif}"
        let aliases = EpubFontAliases.families(css: css) { $0 == "../fonts/book.ttf" ? "Registered Family" : nil }
        XCTAssertEqual(aliases, ["book serif": "Registered Family"])
        XCTAssertTrue(EpubFontAliases.rewrite(css, families: aliases).contains("font-family:\"Registered Family\", Georgia, serif"))
    }

    func testUnavailableAndRemoteFontsKeepNativeFallbackList() {
        var reads: [String] = []
        let css = "@font-face{font-family:Remote;src:url(https://example.invalid/font.ttf)} p{font-family:Remote,serif}"
        XCTAssertTrue(EpubFontAliases.families(css: css) { reads.append($0); return nil }.isEmpty)
        XCTAssertTrue(reads.isEmpty, "A publisher URL must not fetch or substitute another book's local font.")
        XCTAssertEqual(EpubFontAliases.rewrite(css, families: [:]), css)
    }

    func testInlineFamilyIsRewrittenWithoutChangingVisibleTextOrQuoteBoundaries() {
        let html = "<p style='font-family:Book; color:red'>Book</p>"
        let result = EpubFontAliases.rewriteInlineStyles(html, families: ["book": "Registered Family"])
        XCTAssertEqual(result, "<p style='font-family:\"Registered Family\"; color:red'>Book</p>")
        let doubleQuoted = EpubFontAliases.rewriteInlineStyles("<p style=\"font-family:Book\">Book</p>", families: ["book": "Registered Family"])
        XCTAssertTrue(doubleQuoted.contains("font-family:&quot;Registered Family&quot;"))
    }

    func testCommentedFaceAndCaseVariationsCannotSelectAnUnrelatedFamily() {
        let css = "/* @font-face{font-family:Wrong;src:url(wrong.ttf)} */ @FONT-FACE{font-family:BOOK;src:url('right.ttf')}"
        var requested: [String] = []
        let aliases = EpubFontAliases.families(css: css) { requested.append($0); return "Right" }
        XCTAssertEqual(requested, ["right.ttf"])
        XCTAssertEqual(aliases, ["book": "Right"])
        XCTAssertEqual(EpubFontAliases.rewrite("p{font-family:'bOoK', serif}", families: aliases), "p{font-family:\"Right\", serif}")
    }

    func testImportantDeclarationAndLiteralProseRemainIntact() {
        XCTAssertEqual(EpubFontAliases.rewrite("p{font-family:Book,serif !important}", families: ["book": "Native"]),
            "p{font-family:\"Native\", serif !important}")
        let prose = "<p>Print style='font-family:Book' literally.</p>"
        XCTAssertEqual(EpubFontAliases.rewriteInlineStyles(prose, families: ["book": "Native"]), prose)
    }
}
