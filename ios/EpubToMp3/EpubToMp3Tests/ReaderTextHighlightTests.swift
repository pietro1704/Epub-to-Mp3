import XCTest
@testable import EpubToMp3

final class ReaderTextHighlightTests: XCTestCase {
    func testActiveSentenceRangeUsesSentenceTextInAttributedReaderContent() {
        let content = NSAttributedString(string: "Before. The blame was mostly laid on Gandalf. After.")
        let spans = [
            SentenceSpan(
                id: "chapter-2:sentence-1",
                text: "The blame was mostly laid on Gandalf.",
                startChar: 8,
                endChar: 45
            )
        ]

        let range = ReaderTextHighlight.range(
            for: "chapter-2:sentence-1",
            spans: spans,
            in: content
        )

        guard let range else {
            return XCTFail("The active sentence must resolve to a text range")
        }
        XCTAssertEqual(
            (content.string as NSString).substring(with: range),
            "The blame was mostly laid on Gandalf."
        )
    }

    func testMissingOrInactiveSentenceDoesNotHighlightReaderContent() {
        let content = NSAttributedString(string: "The sentence.")
        let spans = [SentenceSpan(id: "known", text: "The sentence.", startChar: 0, endChar: 13)]

        XCTAssertNil(ReaderTextHighlight.range(for: nil, spans: spans, in: content))
        XCTAssertNil(ReaderTextHighlight.range(for: "unknown", spans: spans, in: content))
    }
}
