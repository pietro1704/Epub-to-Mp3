import XCTest
@testable import EpubToMp3

/// Unit tests for the queued-chapter URL-swap decision (Bug B).
///
/// `AudioPlayer.updateSnapshot` used to be append-only: a chapter whose
/// `downloadUrl` changed (re-synthesis / retry produced a new file at the same
/// index) was never reflected in the AVQueuePlayer, so the reader/player kept
/// the stale audio — "the chapter that doesn't update". The pure decision
/// `chapterIndicesNeedingURLSwap` picks exactly which future chapters to swap,
/// never the one currently playing.
final class AudioPlayerURLSwapTests: XCTestCase {

    private func chapter(_ index: Int, url: String?) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index, name: "Ch \(index)", status: "completed",
            downloadUrl: url, chars: 1, charsProcessed: 1,
            progressRatio: 1, durationSeconds: 1, startedAt: nil, completedAt: nil
        )
    }

    func testSwapsFutureChapterWhoseURLChanged() {
        let old = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: "/2.mp3")]
        let new = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: "/2-v2.mp3")]
        let result = AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: new, currentlyPlayingIndex: 0)
        XCTAssertEqual(result, [2])
    }

    func testNeverSwapsCurrentlyPlayingChapter() {
        // Chapter 1 is playing; even though its URL changed, it must not be
        // swapped (that would yank the live item and break the playhead).
        let old = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: "/2.mp3")]
        let new = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1-v2.mp3"), chapter(2, url: "/2.mp3")]
        let result = AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: new, currentlyPlayingIndex: 1)
        XCTAssertEqual(result, [], "The chapter currently playing must never be swapped.")
    }

    func testNeverSwapsPastChapters() {
        // Chapter 0 already played; its URL changing is irrelevant to the queue.
        let old = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3")]
        let new = [chapter(0, url: "/0-v2.mp3"), chapter(1, url: "/1.mp3")]
        let result = AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: new, currentlyPlayingIndex: 1)
        XCTAssertEqual(result, [])
    }

    func testNoSwapWhenURLsUnchanged() {
        let old = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: "/2.mp3")]
        let result = AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: old, currentlyPlayingIndex: 0)
        XCTAssertEqual(result, [])
    }

    func testIgnoresNilOrEmptyNewURL() {
        // A future chapter losing its URL (nil/empty) is not a re-synthesis to
        // swap in — leave the existing item alone.
        let old = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: "/2.mp3")]
        let newNil = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: nil)]
        let newEmpty = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: "")]
        XCTAssertEqual(AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: newNil, currentlyPlayingIndex: 0), [])
        XCTAssertEqual(AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: newEmpty, currentlyPlayingIndex: 0), [])
    }

    func testOnlyComparesSharedPrefixNotAppendedChapters() {
        // Appended chapters (new.count > old.count) are handled by the append
        // path, not the swap path — the swap decision only spans shared indices.
        let old = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3")]
        let new = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1-v2.mp3"), chapter(2, url: "/2.mp3")]
        let result = AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: new, currentlyPlayingIndex: 0)
        XCTAssertEqual(result, [1], "Only the changed shared-prefix chapter is a swap; index 2 is an append.")
    }

    func testMultipleFutureSwaps() {
        let old = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1.mp3"), chapter(2, url: "/2.mp3"), chapter(3, url: "/3.mp3")]
        let new = [chapter(0, url: "/0.mp3"), chapter(1, url: "/1-v2.mp3"), chapter(2, url: "/2.mp3"), chapter(3, url: "/3-v2.mp3")]
        let result = AudioPlayer.chapterIndicesNeedingURLSwap(old: old, new: new, currentlyPlayingIndex: 0)
        XCTAssertEqual(result, [1, 3])
    }
}
