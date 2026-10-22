import Foundation

/// Derived from `snapshot`, recomputed only when `snapshot` is reassigned
/// (once per SSE/poll update), not on every read. The segmented playback
/// progress bars in the native player poll this from a
/// `CADisplayLink` at up to 30 fps — reconstructing `BookChapterProgress`
/// (sort + map + two reduce over every chapter) on each of those ticks
/// would burn main-thread time on a large book for no reason, since the
/// underlying data hasn't changed between ticks.
@MainActor
final class PlaybackBookProgress {
    private(set) var value: BookChapterProgress?
    func update(_ snapshot: JobSnapshot?) {
        guard let snapshot, snapshot.chapterProgress?.isEmpty == false else {
            value = nil
            return
        }
        value = BookChapterProgress(snapshot: snapshot)
    }
}
