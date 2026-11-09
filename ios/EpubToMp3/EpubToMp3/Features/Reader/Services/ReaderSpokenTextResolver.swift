import Foundation

/// Maps measured utterance ranges to publisher-rendered text without choosing
/// another occurrence of a repeated phrase. Whitespace may differ after HTML import.
enum ReaderSpokenTextResolver {
    static func word(_ spoken: SpeechAudioAlignment.Word, passage: SpeechAudioAlignment.Passage,
                     chapterText: String, renderedText: String) -> NSRange? {
        ranges(passage: passage, chapterText: chapterText, renderedText: renderedText)[spoken.location]
    }

    static func ranges(passage: SpeechAudioAlignment.Passage, chapterText: String,
                       renderedText: String) -> [Int: NSRange] {
        guard let expression = expression(for: passage.text) else { return [:] }
        let rendered = expression.matches(in: renderedText, range: NSRange(renderedText.startIndex..., in: renderedText))
        let match: NSTextCheckingResult
        if rendered.count == 1, let only = rendered.first {
            match = only
        } else if let source = passage.sourceOffset {
            let scalars = chapterText.unicodeScalars
            guard source <= scalars.count else { return [:] }
            let index = scalars.index(scalars.startIndex, offsetBy: source)
            let offset = index.utf16Offset(in: chapterText)
            let canonical = expression.matches(in: chapterText, range: NSRange(chapterText.startIndex..., in: chapterText))
            guard let occurrence = canonical.firstIndex(where: { $0.range.location == offset }),
                  canonical.count == rendered.count else { return [:] }
            match = rendered[occurrence]
        } else { return [:] }
        // Each non-whitespace run has a capture, so changes in HTML whitespace
        // cannot shift later words. A marker must fit inside one captured run.
        let source = passage.text as NSString
        let tokens = (try? NSRegularExpression(pattern: "\\S+").matches(in: passage.text,
            range: NSRange(location: 0, length: source.length))) ?? []
        var ranges: [Int: NSRange] = [:]
        for spoken in passage.words {
            guard let token = tokens.firstIndex(where: { NSIntersectionRange($0.range, spoken.range) == spoken.range }),
                  token + 1 < match.numberOfRanges else { continue }
            let range = match.range(at: token + 1)
            let delta = spoken.location - tokens[token].range.location
            let result = NSRange(location: range.location + delta, length: spoken.length)
            guard NSMaxRange(result) <= NSMaxRange(range),
                  (renderedText as NSString).substring(with: result) == source.substring(with: spoken.range) else { continue }
            ranges[spoken.location] = result
        }
        return ranges
    }

    private static func expression(for text: String) -> NSRegularExpression? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return nil }
        let pattern = tokens.map { "(" + NSRegularExpression.escapedPattern(for: String($0)) + ")" }.joined(separator: "\\s+")
        return try? NSRegularExpression(pattern: pattern)
    }
}
