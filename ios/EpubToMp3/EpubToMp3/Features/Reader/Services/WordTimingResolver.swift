import Foundation

struct WordTiming: Equatable, Hashable, Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
}

enum WordTimingResolver {
    static func activeWord(
        in sentence: SentenceSpan,
        elapsed: TimeInterval,
        sentenceDuration: TimeInterval,
        realTiming: [WordTiming]?
    ) -> WordTiming? {
        let timings = (realTiming?.isEmpty == false) ? realTiming! : estimate(in: sentence, sentenceDuration: sentenceDuration)
        return timings.last(where: { elapsed >= $0.start && elapsed < $0.end })
            ?? timings.last(where: { elapsed >= $0.start && elapsed <= $0.end })
    }

    static func estimate(in sentence: SentenceSpan, sentenceDuration: TimeInterval) -> [WordTiming] {
        guard sentenceDuration > 0 else { return [] }
        let words = sentence.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        let totalWeight = words.reduce(0) { $0 + Double(max(1, $1.count)) }
        var cursor: TimeInterval = 0
        return words.map { word in
            let duration = sentenceDuration * Double(max(1, word.count)) / totalWeight
            defer { cursor += duration }
            return WordTiming(word: word, start: cursor, end: cursor + duration)
        }
    }
}
