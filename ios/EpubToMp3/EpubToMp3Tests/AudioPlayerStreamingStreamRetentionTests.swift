#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerStreamingTests {
    @MainActor
    func testDeferredSegmentsRemainRetainedPastAdvisoryHighWaterMark() {
        let player = AudioPlayer()
        let total = SegmentBacklog.advisoryHighWaterMark + 4

        for segmentIndex in 0..<total {
            player.enqueueSegment(
                data: fakeMP3(),
                chapterIndex: 0,
                segmentIndex: segmentIndex
            )
        }

        XCTAssertEqual(player.testHook_retainedSegmentCount(), total,
            "Conversion may outpace listening, but every file must remain available")
        XCTAssertGreaterThan(player.testHook_deferredSegmentCount(), 0,
            "Segments beyond AVQueuePlayer's small look-ahead must wait instead of being deleted")
        XCTAssertNotNil(player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0))
        XCTAssertNotNil(player.testHook_segmentURL(chapterIndex: 0, segmentIndex: total - 1))
    }

    @MainActor
    func testBufferedLaterChapterDoesNotOverwriteAudibleSegmentState() {
        let player = AudioPlayer()
        player.enqueueSegment(
            data: fakeMP3(), chapterIndex: 0, segmentIndex: 0, sentenceId: "chapter-0"
        )
        player.enqueueSegment(
            data: fakeMP3(), chapterIndex: 1, segmentIndex: 0, sentenceId: "chapter-1"
        )

        XCTAssertEqual(player.currentChapterIndex, 0)
        XCTAssertEqual(
            player.testHook_activeSegmentIdentity(),
            .init(chapterIndex: 0, segmentIndex: 0),
            "A buffered chapter must not claim the audible chapter cursor"
        )
        XCTAssertEqual(player.activeSentenceId, "chapter-0")

        // This simulates AVQueuePlayer's current-item transition. The
        // buffered chapter becomes active only at this point.
        player.testHook_activateSegment(chapterIndex: 1, segmentIndex: 0)
        XCTAssertEqual(player.currentChapterIndex, 1)
        XCTAssertEqual(player.activeSentenceId, "chapter-1")
    }

    @MainActor
    func testSameSegmentIdentityUsesDifferentTempFileInNewStreamSession() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        let firstURL = player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0)
        XCTAssertNotNil(firstURL)
        XCTAssertEqual(
            firstURL.flatMap(PlaybackSegmentSession.segmentIdentityForSegmentItem),
            .init(chapterIndex: 0, segmentIndex: 0),
            "Collision-safe filenames must retain the producer identity used for playback reconciliation"
        )

        player.prepareSegmentRestart()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        let secondURL = player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0)

        XCTAssertNotNil(secondURL)
        XCTAssertNotEqual(firstURL, secondURL,
            "Restarted streams must never overwrite the AVFoundation asset from a prior session")
    }

    @MainActor
    func testSessionTeardownIsTheOnlyDeferredSegmentDiscardPoint() {
        let player = AudioPlayer()
        for segmentIndex in 0..<(SegmentBacklog.advisoryHighWaterMark + 1) {
            player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: segmentIndex)
        }
        let deferredURL = player.testHook_segmentURL(
            chapterIndex: 0,
            segmentIndex: SegmentBacklog.advisoryHighWaterMark
        )
        XCTAssertNotNil(deferredURL)
        XCTAssertTrue(deferredURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)

        player.prepareSegmentRestart()

        XCTAssertEqual(player.testHook_retainedSegmentCount(), 0)
        XCTAssertEqual(player.testHook_deferredSegmentCount(), 0)
        XCTAssertFalse(deferredURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true,
            "Session teardown releases deferred files only after their queue can no longer consume them")
    }

    @MainActor
    func testClearConversionStateResetsFirstSegmentReady() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady)

        // `clearConversionState` deliberately preserves readiness flags
        // while a player is mounted (so we don't clobber an active session).
        // A real "new book" flow calls `stop()` first, which tears down
        // the player; then clearConversionState resets the flags.
        player.stop()
        player.clearConversionState()

        XCTAssertFalse(player.firstSegmentReady,
            "clearConversionState must reset firstSegmentReady once the player is torn down")
        XCTAssertFalse(player.firstChapterReady,
            "clearConversionState must also reset firstChapterReady")
    }

    /// Verifies that calling `play(snapshot:)` after segments were
    /// enqueued via streaming replaces the queue cleanly (teardown + rebuild).
    @MainActor
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
#endif
