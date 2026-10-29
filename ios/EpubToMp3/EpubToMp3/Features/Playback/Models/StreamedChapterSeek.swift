import Foundation

/// Resolves chapter time using measured, contiguous segment durations. A
/// buffered endpoint is not a chapter endpoint until completion confirms it.
struct StreamedChapterSeek {
    struct Target: Equatable {
        let segmentIndex: Int
        let offset: TimeInterval
        let chapterBase: TimeInterval
    }

    enum Resolution: Equatable {
        case waiting
        case ready(Target)
    }

    static func resolve(position: TimeInterval, startingPosition: TimeInterval = 0,
                        durations: [TimeInterval], allowsFinalEndpoint: Bool = false) -> Resolution? {
        guard position.isFinite, startingPosition.isFinite, startingPosition >= 0,
              position >= startingPosition,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        var base = startingPosition
        for (index, duration) in durations.enumerated() {
            let end = base + duration
            guard end.isFinite else { return nil }
            if position < end || (allowsFinalEndpoint && index == durations.count - 1 && position == end) {
                return .ready(.init(segmentIndex: index, offset: position - base, chapterBase: base))
            }
            base = end
        }
        return .waiting
    }
}
