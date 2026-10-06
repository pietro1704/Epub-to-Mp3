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

    /// A saved highlight's stored offsets can drift if the chapter is
    /// re-rendered with different settings (font/theme) before reopening.
    /// `range(for:in:)` must still find the words via substring search
    /// instead of silently dropping the highlight.
    func testStaleOffsetFallsBackToSubstringSearch() {
        let content = NSAttributedString(string: "Prefix changed. The blame was mostly laid on Gandalf. Suffix.")
        let span = SentenceSpan(
            id: "s1", text: "The blame was mostly laid on Gandalf.",
            startChar: 0, endChar: 10 // stale — no longer points at the sentence
        )

        let range = ReaderTextHighlight.range(for: span, in: content)

        guard let range else {
            return XCTFail("Expected substring-search fallback to locate the sentence")
        }
        XCTAssertEqual(
            (content.string as NSString).substring(with: range),
            "The blame was mostly laid on Gandalf."
        )
    }

    func testEmptySpanTextWithStaleOffsetReturnsNil() {
        let content = NSAttributedString(string: "Short.")
        let span = SentenceSpan(id: "s1", text: "", startChar: 100, endChar: 120)

        XCTAssertNil(ReaderTextHighlight.range(for: span, in: content))
    }
}
