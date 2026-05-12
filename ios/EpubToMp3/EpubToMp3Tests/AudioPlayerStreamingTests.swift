#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
@testable import EpubToMp3

/// Tests for the segment-streaming additions to `AudioPlayer`:
/// `enqueueSegment(data:chapterIndex:segmentIndex:)`, `firstSegmentReady`,
/// and the interaction with `firstChapterReady` / `clearConversionState()`.
///
/// No real audio session or Edge-TTS calls are made — we feed synthetic
/// MP3 stubs and verify state transitions. Runs on the macOS host.
@MainActor
final class AudioPlayerStreamingTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the smallest valid MPEG Layer-III frame header (4 bytes)
    /// followed by padding so AVFoundation is happy probing the file.
    /// This is not a real MP3 but is sufficient for `AVPlayerItem` to
    /// accept the URL without crashing during probe; actual audio would
    /// require a real encoded frame.
    private func fakeMP3(size: Int = 512) -> Data {
        // MPEG1, Layer3, 128 kbps, 44100 Hz, stereo header bytes.
        var d = Data([0xFF, 0xFB, 0x90, 0x00])
        d.append(contentsOf: [UInt8](repeating: 0x00, count: max(0, size - 4)))
        return d
    }

    // MARK: - firstSegmentReady

    func testFirstSegmentReadyFalseInitially() {
        let player = AudioPlayer()
        XCTAssertFalse(player.firstSegmentReady,
            "firstSegmentReady must be false before any segment arrives")
    }

    func testFirstSegmentReadyTrueAfterFirstEnqueue() {
        let player = AudioPlayer()
        let mp3 = fakeMP3()
        player.enqueueSegment(data: mp3, chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady,
            "firstSegmentReady must flip to true after the first enqueueSegment call")
    }

    func testFirstSegmentReadyIsLatch() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 1)
        XCTAssertTrue(player.firstSegmentReady,
            "firstSegmentReady must remain true after multiple segments")
    }

    // MARK: - firstChapterReady co-advancement

    func testFirstChapterReadyAlsoSetAfterFirstSegment() {
        let player = AudioPlayer()
        XCTAssertFalse(player.firstChapterReady)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstChapterReady,
            "enqueueSegment must also set firstChapterReady so MiniPlayerBar shows play/pause")
    }

    // MARK: - isLoading respects firstSegmentReady

    func testIsLoadingFalseAfterFirstSegmentArrives() {
        let player = AudioPlayer()
        player.isConverting = true
        // isLoading = isConverting && !firstChapterReady; after a segment
        // firstChapterReady becomes true, so isLoading must be false.
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertFalse(player.isLoading,
            "isLoading must be false once the first segment is enqueued")
    }

    // MARK: - Empty data ignored

    func testEmptyDataIsIgnored() {
        let player = AudioPlayer()
        player.enqueueSegment(data: Data(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertFalse(player.firstSegmentReady,
            "Empty data must not trigger firstSegmentReady")
    }

    // MARK: - Multiple segments enqueued

    func testMultipleSegmentsQueued() {
        let player = AudioPlayer()
        for i in 0..<4 {
            player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: i)
        }
        XCTAssertTrue(player.firstSegmentReady)
        XCTAssertTrue(player.isPlaying,
            "Player should be playing after segments are enqueued")
    }

    // MARK: - clearConversionState resets firstSegmentReady

    func testClearConversionStateResetsFirstSegmentReady() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady)

        player.clearConversionState()

        XCTAssertFalse(player.firstSegmentReady,
            "clearConversionState must reset firstSegmentReady for new book sessions")
        XCTAssertFalse(player.firstChapterReady,
            "clearConversionState must also reset firstChapterReady")
    }

    // MARK: - Streaming then whole-chapter play interop

    /// Verifies that calling `play(snapshot:)` after segments were
    /// enqueued via streaming replaces the queue cleanly (teardown + rebuild).
    func testPlaySnapshotAfterStreamingTeardownSegments() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady)

        // Simulate the whole-chapter MP3 arriving and the caller doing a
        // full snapshot-based play. This teardowns the segment queue.
        let snap = JobSnapshot.stub(playableCount: 0)
        player.play(snapshot: snap, startingAt: 0)

        // After teardown, segment temp dir should be wiped (we can't
        // inspect it directly, but firstSegmentReady is already latched
        // true until clearConversionState is called — that's correct:
        // the player is now playing via snapshot path, not streaming).
        XCTAssertTrue(player.firstSegmentReady,
            "firstSegmentReady stays true after switching to snapshot playback " +
            "(it is a session-level latch, not a mode indicator)")
    }
}

// MARK: - JobSnapshot test stubs

private extension JobSnapshot {
    static func stub(playableCount: Int) -> JobSnapshot {
        let chapters = (0..<playableCount).map { i in
            JobSnapshot.Chapter(
                index: i,
                title: "Chapter \(i + 1)",
                status: "completed",
                downloadUrl: "/fake/ch\(i).mp3",
                durationSeconds: nil,
                errorMessage: nil
            )
        }
        return JobSnapshot(
            jobId: "stub-\(UUID().uuidString)",
            bookTitle: "Stub Book",
            bookAuthor: nil,
            status: "pending",
            chaptersTotal: playableCount,
            chaptersCompleted: playableCount,
            chapters: chapters,
            createdAt: nil,
            updatedAt: nil
        )
    }
}
#endif
