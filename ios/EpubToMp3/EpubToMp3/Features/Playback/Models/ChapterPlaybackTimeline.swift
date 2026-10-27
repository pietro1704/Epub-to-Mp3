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
        let words = (chapter.speechText ?? chapter.text).split(whereSeparator: \.isWhitespace).count
        // Preserve the reader's existing 200 WPM baseline; this is an estimate.
        return Double(words) / 200 * 60
    }

    static func estimates(for chapters: [EbookFulltext.Chapter]) -> [Int: TimeInterval] {
        chapters.reduce(into: [:]) { result, chapter in
            result[chapter.zeroBasedEpubIndex] = estimate(for: chapter)
        }
    }

    func remaining(position: TimeInterval, rate: Double) -> TimeInterval {
        guard position.isFinite, rate.isFinite, rate > 0 else { return 0 }
        return max(0, duration - max(0, position)) / rate
    }
}
