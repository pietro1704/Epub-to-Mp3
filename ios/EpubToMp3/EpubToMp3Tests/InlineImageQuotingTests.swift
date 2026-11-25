import XCTest
@testable import EpubToMp3

/// Book HTML may quote attributes either way. Both forms must become bounded inline attachments, which the
/// reader can fit to the page.
@MainActor
final class InlineImageQuotingTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhWMjWwAAAABJRU5ErkJggg=="

    func testADoubleQuotedDataImageBecomesAnAttachment() {
        assertExtracted(#"<p>Before</p><img src="data:image/png;base64,\#(png)" alt="figure"><p>After</p>"#)
    }

    func testASingleQuotedDataImageBecomesAnAttachment() {
        assertExtracted(#"<p>Before</p><img src='data:image/png;base64,\#(png)' alt='figure'><p>After</p>"#)
    }

    private func assertExtracted(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
        let (body, images) = EpubResourcePresentation.extractDataURIImages(html)

        XCTAssertEqual(images.count, 1, file: file, line: line)
        XCTAssertFalse(body.contains("data:image"), "no data URI is left for the HTML importer", file: file, line: line)
        XCTAssertEqual(body, "<p>Before</p>\(images.first?.token ?? "")<p>After</p>", file: file, line: line)
    }
}
