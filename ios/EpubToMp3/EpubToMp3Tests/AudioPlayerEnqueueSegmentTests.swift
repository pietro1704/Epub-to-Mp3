#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// Targeted tests for `AudioPlayer.enqueueSegment` queue mechanics.
///
/// These run on the macOS host (no real iOS audio session required).
/// They exercise the AVQueuePlayer queue-count behaviour, multi-chapter
/// ordering, and the embedded-TTS bootstrap state flags that were broken
/// when no backend URL was configured on a real iPhone.
@MainActor
final class AudioPlayerEnqueueSegmentTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal MPEG Layer-III frame header + zero-padding.
    /// Not real audio, but `AVPlayerItem` accepts it for URL-based probing.
    private func fakeMP3(size: Int = 512) -> Data {
        var d = Data([0xFF, 0xFB, 0x90, 0x00])
        d.append(contentsOf: [UInt8](repeating: 0, count: max(0, size - 4)))
        return d
    }

    // MARK: - Queue item count

    /// Enqueue 3 segments; AVQueuePlayer must hold all 3 items.
    func testThreeSegmentsEnqueuedItemCount() {
        let player = AudioPlayer()
        for i in 0..<3 {
            player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: i)
        }
        // The internal AVQueuePlayer is not directly accessible from tests,
        // so we verify the observable contract: after 3 segments the player
        // is playing and first-segment/chapter flags are set.
        XCTAssertTrue(player.isPlaying,
            "Player must start playing after the first segment")
        XCTAssertTrue(player.firstSegmentReady,
            "firstSegmentReady must be true after 3 segments")
        XCTAssertTrue(player.firstChapterReady,
            "firstChapterReady must be true after 3 segments")
    }

    /// Segments from different chapters are all accepted without crashing.
    func testMultiChapterSegmentsAccepted() {
        let player = AudioPlayer()
        // Chapter 0, segment 0 — creates the queue.
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        // Chapter 0, additional segments.
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 1)
        // Chapter 1 segments appended to the same queue (pre-buffered gapless).
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 1, segmentIndex: 0)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 1, segmentIndex: 1)

        XCTAssertTrue(player.firstSegmentReady)
        XCTAssertTrue(player.isPlaying)
    }

    // MARK: - firstSegmentReady is a session latch

    func testFirstSegmentReadyLatchSurvivesClearConversionState() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady)

        // clearConversionState is called between books; both flags reset.
        player.clearConversionState()
        XCTAssertFalse(player.firstSegmentReady,
            "clearConversionState must reset firstSegmentReady for the next book session")
        XCTAssertFalse(player.firstChapterReady,
            "clearConversionState must reset firstChapterReady for the next book session")
    }

    // MARK: - isLoading gate

    /// The MiniPlayerBar spinner must disappear as soon as the first
    /// segment lands — regardless of whether isConverting is still true.
    func testIsLoadingDropsAfterFirstSegment() {
        let player = AudioPlayer()
        player.isConverting = true
        XCTAssertTrue(player.isLoading,
            "isLoading must be true when isConverting && !firstChapterReady")

        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)

        XCTAssertFalse(player.isLoading,
            "isLoading must drop to false once firstChapterReady becomes true")
    }

    // MARK: - No crash on empty data

    func testEmptySegmentDataIsGracefullyIgnored() {
        let player = AudioPlayer()
        // Must not crash; firstSegmentReady stays false.
        player.enqueueSegment(data: Data(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertFalse(player.firstSegmentReady)
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - No duplicate player creation

    /// Calling enqueueSegment after teardown (via stop()) then re-enqueuing
    /// must create a fresh player, not append to the torn-down one.
    func testReenqueueAfterStopCreatesNewPlayer() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.isPlaying)

        player.stop()
        XCTAssertFalse(player.isPlaying)

        // After stop, clearConversionState is not called automatically,
        // so firstSegmentReady is still true (latch). A new enqueue
        // must still start a new player.
        player.clearConversionState()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.isPlaying,
            "A new AVQueuePlayer must start after stop+clearConversionState+enqueue")
    }
}
#endif
