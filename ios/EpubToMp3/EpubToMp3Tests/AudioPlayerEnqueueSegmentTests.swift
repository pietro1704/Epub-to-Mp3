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
    ///
    /// Updated contract: incoming SSE segments NO LONGER auto-start
    /// playback — the user must tap Play explicitly. The first
    /// segment only flips the "ready" latches so the Play button
    /// enables in the UI.
    func testThreeSegmentsEnqueuedItemCount() {
        let player = AudioPlayer()
        for i in 0..<3 {
            player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: i)
        }
        XCTAssertFalse(player.isPlaying,
            "First segment must not auto-start playback — that would " +
            "claim audio focus from Spotify / Music without user intent")
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
        // Per the no-auto-play rule, the queue is paused until the
        // user explicitly resumes.
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - firstSegmentReady is a session latch

    func testFirstSegmentReadyLatchSurvivesClearConversionState() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady)

        // `clearConversionState` is gated on `!isPlaying && player ==
        // nil` so it can't blow away latches mid-playback (would
        // flicker the play/spinner button). Caller must `stop()`
        // first when switching books — that is the realistic
        // sequence the BookOpenView.onDisappear flow takes.
        player.stop()
        player.clearConversionState()
        XCTAssertFalse(player.firstSegmentReady,
            "clearConversionState (after stop) must reset firstSegmentReady for the next book session")
        XCTAssertFalse(player.firstChapterReady,
            "clearConversionState (after stop) must reset firstChapterReady for the next book session")
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

    // MARK: - Background pre-synthesis must not march the chapter cursor

    /// Regression: while PAUSED (background conversion — reader open but the
    /// user hasn't tapped Play), `BookOpenView.synthesizeOneChapter` streams
    /// segments for the whole book in chapter order. Each new chapter used to
    /// clobber `currentChapterIndex`, marching the user's cursor 0→N across
    /// every chapter. A follow-mode reader observing the player then followed
    /// that runaway and re-rendered ~60×/s (device log: 86 ReaderView.init on
    /// a stationary chapter). A paused player MUST keep its cursor put.
    func testBackgroundEnqueueDoesNotMoveCursorWhilePaused() {
        let player = AudioPlayer()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentChapterIndex, 0)

        // Simulate whole-book background synthesis: segments for many
        // chapters, out of and in order, all while paused.
        for ch in [0, 1, 2, 5, 9, 20, 47] {
            player.enqueueSegment(data: fakeMP3(), chapterIndex: ch, segmentIndex: 0)
            XCTAssertFalse(player.isPlaying,
                "enqueue must never auto-start playback")
            XCTAssertEqual(player.currentChapterIndex, 0,
                "a paused player must not move its chapter cursor to chapter \(ch) " +
                "just because a background-synthesized segment was enqueued")
        }
    }

    /// Buffered chapters must not pull the reader/Now Playing cursor ahead of
    /// the item AVQueuePlayer is actually playing.
    func testBufferingAheadWhilePlayingDoesNotMoveCurrentChapter() {
        let player = AudioPlayer()
        player.testHook_setIsPlaying(true)

        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 1, segmentIndex: 0)

        XCTAssertEqual(player.currentChapterIndex, 0,
            "Buffer-ahead enqueue must not claim chapter 1 before its item becomes current")
    }

    /// Future chapter segments may be buffered while chapter 0 is audible,
    /// but they must not replace the active chapter's sentence timing state
    /// before AVQueuePlayer advances to that chapter.
    func testBufferingAheadPreservesActiveSegmentTimingChapter() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0, sentenceId: "ch0-s0")
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 1, segmentIndex: 0, sentenceId: "ch1-s0")

        XCTAssertEqual(player.testHook_segmentChapterIndex(), 0)
        XCTAssertEqual(player.testHook_activeSegmentSentenceCount(), 1)
    }

    func testSegmentsWithoutSentenceIDsPreserveTimingAlignment() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 1, sentenceId: "ch0-s1")

        XCTAssertEqual(
            player.testHook_activeSegmentSentenceCount(),
            2,
            "Every queued segment must occupy a timing slot, even when it has no sentence ID"
        )
    }

    func testActivatingNewChapterDiscardsPlayedChapterSentenceMetadata() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0, sentenceId: "ch0-s0")
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 1, segmentIndex: 0, sentenceId: "ch1-s0")

        player.testHook_activateSegmentChapter(1)

        XCTAssertEqual(player.testHook_bufferedSegmentChapterCount(), 1)
        XCTAssertEqual(player.activeSentenceId, "ch1-s0")
    }

    func testDelayedCompletionFromPreviousChapterDoesNotAdvanceNewChapterCursor() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0, sentenceId: "ch0-s0")
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 1, segmentIndex: 0, sentenceId: "ch1-s0")
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 1, segmentIndex: 1, sentenceId: "ch1-s1")

        player.testHook_activateSegmentChapter(1)
        player.testHook_completeSegmentTiming(chapterIndex: 0)

        XCTAssertEqual(player.activeSentenceId, "ch1-s0")
        XCTAssertEqual(player.testHook_activeSegmentSentenceCount(), 2)
    }

    func testOwnedSegmentItemRequiresSameInstanceAndCanBeRemovedWhenSkipped() {
        let player = AudioPlayer()
        let owned = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/owned-segment.mp3"))
        let unrelated = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/unrelated-segment.mp3"))

        player.testHook_registerOwnedSegmentItem(owned)

        XCTAssertTrue(player.testHook_isOwnedSegmentItem(owned))
        XCTAssertFalse(player.testHook_isOwnedSegmentItem(unrelated))

        player.testHook_removeOwnedSegmentItem(owned)

        XCTAssertFalse(player.testHook_isOwnedSegmentItem(owned))
    }

    func testTeardownClearsDeferredSegmentsBeforeDeletingSessionDirectory() {
        let player = AudioPlayer()

        for segmentIndex in 0...5 {
            player.enqueueSegment(
                data: fakeMP3(),
                chapterIndex: 0,
                segmentIndex: segmentIndex,
                sentenceId: "s\(segmentIndex)"
            )
        }

        XCTAssertGreaterThan(player.testHook_backlogCount(), 0)

        player.testHook_teardownPlayer()

        XCTAssertEqual(
            player.testHook_backlogCount(),
            0,
            "A new playback session must not inherit deferred files from the previous queue"
        )
    }

    func testSegmentProducerWaitsAtBoundedBacklogUntilQueueAdvances() async {
        let player = AudioPlayer()
        let total = AudioPlayer.testHook_maxQueueAhead()
            + SegmentBacklog.maximumDeferredSegmentCount
        for segmentIndex in 0..<total {
            player.enqueueSegment(
                data: fakeMP3(),
                chapterIndex: 0,
                segmentIndex: segmentIndex
            )
        }
        XCTAssertEqual(
            player.testHook_backlogCount(),
            SegmentBacklog.maximumDeferredSegmentCount
        )

        let resumed = expectation(description: "segment capacity resumed")
        let waiting = expectation(description: "segment producer is waiting")
        Task { @MainActor in
            waiting.fulfill()
            if await player.waitForSegmentCapacity() {
                resumed.fulfill()
            }
        }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertEqual(
            player.testHook_backlogCount(),
            SegmentBacklog.maximumDeferredSegmentCount,
            "The producer must remain paused while the deferred backlog is full"
        )
        XCTAssertEqual(player.testHook_segmentCapacityWaiterCount(), 1)

        XCTAssertTrue(player.testHook_finishCurrentSegment())
        await fulfillment(of: [resumed], timeout: 1)
    }

    func testTeardownCancelsAProducerWaitingForSegmentCapacity() async {
        let player = AudioPlayer()
        let total = AudioPlayer.testHook_maxQueueAhead()
            + SegmentBacklog.maximumDeferredSegmentCount
        for segmentIndex in 0..<total {
            player.enqueueSegment(
                data: fakeMP3(),
                chapterIndex: 0,
                segmentIndex: segmentIndex
            )
        }

        let cancelled = expectation(description: "segment capacity cancelled")
        let waiting = expectation(description: "segment producer is waiting")
        Task { @MainActor in
            waiting.fulfill()
            if !(await player.waitForSegmentCapacity()) {
                cancelled.fulfill()
            }
        }
        await fulfillment(of: [waiting], timeout: 1)
        XCTAssertEqual(player.testHook_segmentCapacityWaiterCount(), 1)

        player.testHook_teardownPlayer()
        await fulfillment(of: [cancelled], timeout: 1)
    }

    // MARK: No crash on empty data

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
    ///
    /// Updated contract: no auto-play. We verify a new player was
    /// created by observing `firstSegmentReady` flipping back to true
    /// after `clearConversionState()` reset it.
    func testReenqueueAfterStopCreatesNewPlayer() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady)

        player.stop()
        XCTAssertFalse(player.isPlaying)

        // clearConversionState resets both ready latches.
        player.clearConversionState()
        XCTAssertFalse(player.firstSegmentReady)
        // Re-enqueue: a fresh player is created and the latch flips
        // back. (The queue stays paused — only an explicit user tap
        // on Play kicks off playback.)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady,
            "A new AVQueuePlayer must be set up after stop+clearConversionState+enqueue")
    }
}
#endif
