import Foundation

struct TextParagraph: Equatable, Hashable, Sendable {
    let id: String
    let startChar: Int
    let endChar: Int
}

enum PlaybackTarget: Equatable, Sendable {
    case sentence(SentenceSpan)
}

enum PlaybackTargetResolver {
    static func phraseTarget(for selection: NSRange, spans: [SentenceSpan]) -> PlaybackTarget? {
        guard let span = containingSpan(for: selection, spans: spans) else { return nil }
        return .sentence(span)
    }

    static func paragraphTarget(
        for selection: NSRange,
        spans: [SentenceSpan],
        paragraphs: [TextParagraph]
    ) -> PlaybackTarget? {
        guard let paragraph = paragraphs.first(where: { overlaps(selection, start: $0.startChar, end: $0.endChar) }),
              let firstSentence = spans.first(where: { $0.startChar >= paragraph.startChar && $0.endChar <= paragraph.endChar })
        else { return nil }
        return .sentence(firstSentence)
    }

    private static func containingSpan(for selection: NSRange, spans: [SentenceSpan]) -> SentenceSpan? {
        spans.first { overlaps(selection, start: $0.startChar, end: $0.endChar) }
    }

    private static func overlaps(_ selection: NSRange, start: Int, end: Int) -> Bool {
        let selectionEnd = selection.location + max(selection.length, 1)
        return selection.location < end && selectionEnd > start
    }
}
