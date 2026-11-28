import PDFKit
import XCTest
@testable import EpubToMp3

/// Rust leaves running headers and page numbers out of the narration. Those pages must still map,
/// or "listen from here" and the follow highlight have no position on them.
final class PDFRunningLinesAnchorTests: XCTestCase {
    private let sentences = [
        "The lighthouse keeper writes the first entry in the harbor journal.",
        "A long crossing begins when the morning tide leaves the stone pier.",
        "The boat returns at dusk and the crew counts every lantern again.",
    ]

    func testPagesWithARunningHeaderAndPageNumberMapToTheNarration() throws {
        let audioMap = try map(pages: sentences.enumerated().map {
            (heading: "The Synthetic Book", body: "\($0.element)\n\n\($0.offset + 1)")
        })

        assertEveryPageMapsToItsSentence(audioMap)
    }

    /// Control: the same sentences without repeated lines.
    func testPagesWithoutRepeatedLinesMapToTheNarration() throws {
        let headings = ["Alpha", "Bravo", "Charlie"]
        let audioMap = try map(pages: sentences.enumerated().map {
            (heading: headings[$0.offset], body: $0.element)
        })

        assertEveryPageMapsToItsSentence(audioMap)
    }

    private func map(pages: [(heading: String, body: String)]) throws -> PDFReadingAudioMap {
        let source = try PdfFixture.createMultiPage(pages: pages)
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try XCTUnwrap(PDFDocument(url: source))
        let metadata = try ConverterFFIAdapter().openBook(at: source).metadataJSON
        return try PDFReadingAudioMap(metadata: metadata,
            pageTexts: (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" })
    }

    private func assertEveryPageMapsToItsSentence(_ audioMap: PDFReadingAudioMap,
                                                  file: StaticString = #filePath, line: UInt = #line) {
        for (page, sentence) in sentences.enumerated() {
            guard let anchor = audioMap.anchor(page: page) else {
                XCTFail("page \(page + 1) has no narration position", file: file, line: line)
                continue
            }
            let narration = audioMap.chapters[anchor.chapterIndex].text.unicodeScalars
            let spoken = String(String.UnicodeScalarView(narration.dropFirst(anchor.sourceScalarOffset)))
            // A heading that is narrated may come first.
            XCTAssertTrue(spoken.prefix(40 + sentence.count).contains(sentence),
                          "page \(page + 1) starts at its own sentence, got: \(spoken.prefix(60))", file: file, line: line)
        }
    }
}
