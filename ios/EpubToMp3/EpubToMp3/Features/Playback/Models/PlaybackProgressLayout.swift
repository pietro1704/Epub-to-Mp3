import CoreGraphics
import Foundation

/// Pure layout math for the playback progress bar(s), shared by the
/// `CADisplayLink`-driven UIKit renderer (`PlaybackProgressBar`/
/// `SegmentedPlaybackProgressBar`) and unit tests. Kept UIKit-free so it's
/// testable off-device — mirrors `LibraryGridLayoutMetrics`.
enum PlaybackProgressLayout {
    struct Segment: Equatable {
        let epubIndex: Int
        let frame: CGRect
        let colorState: BookChapterProgress.State
        let isCurrent: Bool
    }

    /// Simple (non-segmented) fill fraction, clamped to `[0, 1]`. Guards
    /// against a zero/NaN duration (book not yet loaded) the same way the
    /// SwiftUI `progress` computed property it replaces did.
    static func fraction(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, duration.isFinite, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// Segment frames for the chapter-weighted progress bar, matching the
    /// SwiftUI `HStack(spacing: 1)` layout it replaces: each chapter gets
    /// `width * weight / totalWeight`, floored at 2pt, laid left to right
    /// with `spacing`-pt gutters.
    static func segments(
        for progress: BookChapterProgress,
        totalWidth: CGFloat,
        height: CGFloat,
        currentPlayableIndex: Int?,
        spacing: CGFloat = 1
    ) -> [Segment] {
        guard totalWidth > 0, !progress.chapters.isEmpty else { return [] }
        let totalWeight = max(1, progress.totalWeight)
        var x: CGFloat = 0
        var result: [Segment] = []
        result.reserveCapacity(progress.chapters.count)
        for chapter in progress.chapters {
            let rawWidth = totalWidth * CGFloat(chapter.weight / totalWeight)
            let width = max(2, rawWidth)
            result.append(Segment(
                epubIndex: chapter.epubIndex,
                frame: CGRect(x: x, y: 0, width: width, height: height),
                colorState: chapter.state,
                isCurrent: chapter.playableIndex != nil && chapter.playableIndex == currentPlayableIndex
            ))
            x += width + spacing
        }
        return result
    }
}
