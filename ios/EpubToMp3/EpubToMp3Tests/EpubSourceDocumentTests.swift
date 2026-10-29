import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class EpubSourceDocumentTests: XCTestCase {
    func testHeadStylesAndRootContextSurviveBodyExtraction() {
        let document = EpubSourceDocument(html: """
        <html lang='pt' class='publisher'><head><link href='book.css'/>
        <style>.poem {text-align:right}</style></head>
        <body class='poem' style='font-family:Georgia'><p>á🙂 Verse.</p></body></html>
        """, css: "p {font-size:16pt}")
        XCTAssertEqual(document.htmlAttributes, " lang='pt' class='publisher'")
        XCTAssertEqual(document.bodyAttributes, " class='poem' style='font-family:Georgia'")
        XCTAssertEqual(document.body, "<p>á🙂 Verse.</p>")
        XCTAssertEqual(document.css, "p {font-size:16pt}\n.poem {text-align:right}")
    }

    func testUppercaseMultilineAndMultipleStyleBlocksPreserveCascadeOrder() {
        let document = EpubSourceDocument(html: """
        <HTML><HEAD><STYLE>p{color:red}</STYLE><STYLE media='all'>p{color:blue}</STYLE></HEAD>
        <BODY\n class="chapter"><p>Body</p></BODY></HTML>
        """, css: nil)
        XCTAssertEqual(document.css, "p{color:red}\np{color:blue}")
        XCTAssertTrue(document.bodyAttributes.contains("class=\"chapter\""))
        XCTAssertEqual(document.body, "<p>Body</p>")
    }

    func testFragmentKeepsReadableMarkupWithoutLeakingStylesOrLinksIntoText() {
        let document = EpubSourceDocument(html: "<style>p{font-size:18pt}</style><link href='x.css'><p>Text</p>", css: nil)
        XCTAssertEqual(document.body, "<p>Text</p>")
        XCTAssertEqual(document.css, "p{font-size:18pt}")
        XCTAssertEqual(document.bodyAttributes, "")
    }
}
