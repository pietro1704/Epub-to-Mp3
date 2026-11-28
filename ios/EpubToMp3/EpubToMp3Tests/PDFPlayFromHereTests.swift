import PDFKit
import XCTest
@testable import EpubToMp3

/// "Play from here" on a PDF with a text layer starts at the touched passage.
final class PDFPlayFromHereTests: XCTestCase {
    func testTouchingAWordFarDownThePageStartsAtThatWord() throws {
        let lines = (1...30).map { "Line \($0) keeps the boat close to the quiet shore." } + ["Finally the zeppelin arrives."]
        let source = try PdfFixture.createMultiPage(pages: [(heading: "Harbour", body: lines.joined(separator: "\n"))])
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let word = text.range(of: "zeppelin")
        let bounds = try XCTUnwrap(page.selection(for: word)).bounds(for: page)

        let character = try XCTUnwrap(PDFReadingAudioMap.character(
            at: CGPoint(x: bounds.minX + 2, y: bounds.midY), on: page))

        XCTAssertEqual(text.substring(from: character).prefix(8), "zeppelin")
    }

    /// The two extractors may disagree on one line; the rest of the page is still the narration.
    func testAPageWithOneLineThatDiffersFromTheNarrationStillStartsWhereTouched() throws {
        let before = (1...8).map { "Line \($0) keeps the boat close to the quiet shore." }
        let after = (9...16).map { "Line \($0) follows the lantern across the silent bay." }
        let shown = (before + ["Mara smiled, tall and stern."] + after).joined(separator: "\n")
        let narrated = (before + ["Mara smiled, proud and serious."] + after).joined(separator: "\n")
        let map = try PDFReadingAudioMap(metadata: metadata(narrated), pageTexts: [shown])
        let touched = (shown as NSString).range(of: "Line 12").location

        let anchor = try XCTUnwrap(map.playbackAnchor(page: 0, character: touched))

        let narration = String(String.UnicodeScalarView(narrated.unicodeScalars.dropFirst(anchor.sourceScalarOffset)))
        XCTAssertTrue(narration.hasPrefix("Line 12 follows"), String(narration.prefix(40)))
    }

    func testAPageThatDoesNotMatchTheNarrationStaysUnavailable() throws {
        let shown = (1...12).map { "Line \($0) belongs to a completely different story." }.joined(separator: "\n")
        let narrated = (1...12).map { "Line \($0) keeps the boat close to the quiet shore." }.joined(separator: "\n")

        let map = try PDFReadingAudioMap(metadata: metadata(narrated), pageTexts: [shown])

        XCTAssertNil(map.playbackAnchor(page: 0))
    }

    private func metadata(_ narration: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["chapters": [
            ["index": "1", "name": "Harbour", "sourcePath": "page-1", "text": narration]]])
    }
}
