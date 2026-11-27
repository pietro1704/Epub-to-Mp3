import Foundation

/// Chapter media time is independent of the amount of audio buffered locally.
struct ChapterPlaybackTimeline: Equatable {
    let duration: TimeInterval
    let isEstimated: Bool

    init(estimate: TimeInterval?, confirmed: TimeInterval?) {
        if let confirmed, confirmed.isFinite, confirmed > 0 {
            duration = confirmed
            isEstimated = false
        } else {
            duration = estimate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
            isEstimated = duration > 0
        }
    }

    static func estimate(for chapter: EbookFulltext.Chapter) -> TimeInterval {
        guard !chapter.isImageOnly else { return 0 }
        return estimate(text: chapter.speechText ?? chapter.text)
    }

    static func estimate(text: String) -> TimeInterval {
        let words = text.split(whereSeparator: \.isWhitespace).count
        // Preserve the reader's existing 200 WPM baseline; this is an estimate.
        return Double(words) / 200 * 60
    }

    static func estimates(for chapters: [EbookFulltext.Chapter]) -> [Int: TimeInterval] {
        chapters.reduce(into: [:]) { result, chapter in
            result[chapter.zeroBasedEpubIndex] = estimate(for: chapter)
        }
    }

    enum RelativePosition: Equatable {
        case target(chapter: Int, time: TimeInterval)
        case needsDuration(chapter: Int)
    }

    /// Walk only the chapters crossed by the offset. A duration estimate is
    /// never proof that a forward skip can leave an unfinished stream.
    static func resolveRelativePosition(
        chapter: Int, time: TimeInterval, chapters: [Int],
        waitForForwardDuration: Bool = true, duration: (Int) -> TimeInterval?
    ) -> RelativePosition? {
        guard time.isFinite, var index = chapters.firstIndex(of: chapter) else { return nil }
        var position = time
        func measured(_ chapter: Int) -> TimeInterval? {
            guard let value = duration(chapter), value.isFinite, value > 0 else { return nil }
            return value
        }

        while position < 0 {
            guard index > chapters.startIndex else { return .target(chapter: chapters[index], time: 0) }
            index -= 1
            let previous = chapters[index]
            guard let length = measured(previous) else { return .needsDuration(chapter: previous) }
            position += length
        }
        while true {
            let current = chapters[index]
            guard let length = measured(current) else {
                return waitForForwardDuration ? .needsDuration(chapter: current) : .target(chapter: current, time: position)
            }
            if position < length { return .target(chapter: current, time: position) }
            guard index < chapters.count - 1 else { return .target(chapter: current, time: length) }
            position -= length
            index += 1
        }
    }

    func remaining(position: TimeInterval, rate: Double) -> TimeInterval {
        guard position.isFinite, rate.isFinite, rate > 0 else { return 0 }
        return max(0, duration - max(0, position)) / rate
    }
}
