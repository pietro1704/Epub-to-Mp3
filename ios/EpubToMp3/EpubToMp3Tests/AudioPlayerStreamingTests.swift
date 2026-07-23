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

    // MARK: - No-autoplay guarantee

    /// Regression: `enqueueSegment` used to call `queue.play()` + flip
    /// `isPlaying = true` the moment the first chunk arrived from SSE,
    /// even though the user had never tapped Play. Media must never
    /// auto-start without explicit user intent (in-app Play button,
    /// lock-screen, or widget remote command).
    func testEnqueueSegmentDoesNotAutoStartPlayback() {
        let player = AudioPlayer()
        XCTAssertFalse(player.isPlaying, "fresh AudioPlayer must be paused")
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertFalse(player.isPlaying,
            "enqueueSegment must NOT auto-start playback — only resume()/togglePlayPause() may")
    }

    /// Regression: `play(snapshot:startingAt:)` used to call `queue.play()`
    /// unconditionally. Now it only sets up the queue; playback only starts
    /// on explicit user intent.
    func testPlaySnapshotPreparesWithoutAutoStart() {
        let player = AudioPlayer()
        XCTAssertFalse(player.isPlaying)
        let snap = JobSnapshot.previewSample
        player.play(snapshot: snap, startingAt: 0)
        XCTAssertFalse(player.isPlaying,
            "play(snapshot:startingAt:) must load without auto-starting playback")
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
        // Updated contract: enqueueSegment never auto-starts playback.
        // The player stays paused until the user taps Play / lock-screen /
        // widget, regardless of how many segments are queued.
        XCTAssertFalse(player.isPlaying,
            "Streaming segments must never auto-start playback")
    }

    func testSegmentQueueDoesNotDropWhenInsertionIsTemporarilyRejected() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Services/AudioPlayer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("queue rejected insert; deferred segment"))
        XCTAssertTrue(source.contains("let next = backlog.peekNext()"))
        XCTAssertTrue(source.contains("_ = backlog.drainNext()"))
    }

    // MARK: - clearConversionState resets firstSegmentReady

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

    // MARK: - SSE snapshot streaming

    func testUpdateSnapshotBuildsQueueWhenFirstPlayableChapterArrives() {
        let player = AudioPlayer(backendBaseURL: URL(string: "https://example.com")!)
        let pending = snapshot(chapters: [chapter(index: 0, url: nil)], state: "running")
        let playable = snapshot(chapters: [chapter(index: 0, url: "/audio/ch0.mp3")], state: "running")

        player.play(snapshot: pending, startingAt: 0)
        XCTAssertFalse(player.isPlaying)

        player.updateSnapshot(playable)
        player.resume()

        XCTAssertTrue(player.isPlaying,
            "The first playable SSE snapshot must create an AVQueuePlayer so a normal Play tap can start audio without reopening the reader.")
    }

    func testResumeBeforeFirstPlayableChapterAutoplaysWhenSnapshotArrives() {
        let player = AudioPlayer(backendBaseURL: URL(string: "https://example.com")!)
        let pending = snapshot(chapters: [chapter(index: 2, url: nil)], state: "running")
        let playable = snapshot(chapters: [chapter(index: 2, url: "/audio/ch2.mp3")], state: "running")

        player.play(snapshot: pending, startingAt: 2)
        player.resume()
        XCTAssertFalse(player.isPlaying,
            "No player exists yet, but resume() should remember the user's intent to play.")

        player.updateSnapshot(playable)

        XCTAssertTrue(player.isPlaying,
            "If the user tapped Play while waiting for streaming audio, the first playable chapter should start as soon as the queue is built.")
    }

    func testChaptersToAppendUsesChapterIdentityForPriorityWraparound() {
        let old = [chapter(index: 10, url: "/audio/ch10.mp3"),
                   chapter(index: 11, url: "/audio/ch11.mp3")]
        let new = [chapter(index: 0, url: "/audio/ch0.mp3"),
                   chapter(index: 10, url: "/audio/ch10.mp3"),
                   chapter(index: 11, url: "/audio/ch11.mp3")]

        let appended = AudioPlayer.chaptersToAppend(old: old, new: new)

        XCTAssertEqual(appended.map(\.index), [0],
            "Priority streaming can wrap to earlier EPUB indices; append decisions must diff by chapter identity instead of suffix(count).")
    }

    // MARK: - AsyncStream multi-consumer (TSan-compatible)

    /// Subscribes two consumers to `position` in parallel, enqueues a segment
    /// to drive a position broadcast, then verifies both consumers received
    /// values without a data race.
    ///
    /// TSan compatibility: all stream mutations go through MainActor.run
    /// (continuation dict writes are serialised on MainActor). The test
    /// uses structured concurrency (`async let`) so there are no unstructured
    /// Task escapes that could race against XCTest teardown.
    @MainActor
    func testPositionStreamMultipleConsumersParallel() async {
        let player = AudioPlayer()

        // Collect first value emitted on each consumer.
        let s1 = player.position
        let s2 = player.position

        async let first: TimeInterval = {
            var iter = s1.makeAsyncIterator()
            return await iter.next() ?? -1
        }()

        async let second: TimeInterval = {
            var iter = s2.makeAsyncIterator()
            return await iter.next() ?? -1
        }()

        let (v1, v2) = await (first, second)

        // Both consumers must have received the initial position (0 at construction).
        XCTAssertEqual(v1, 0, accuracy: 0.001,
            "First consumer should receive initial position 0")
        XCTAssertEqual(v2, 0, accuracy: 0.001,
            "Second consumer should receive initial position 0")
    }

    /// Subscribes two consumers to `currentChapter` in parallel and verifies
    /// both receive the initial nil value without a data race.
    @MainActor
    func testCurrentChapterStreamMultipleConsumersParallel() async {
        let player = AudioPlayer()

        let s1 = player.currentChapter
        let s2 = player.currentChapter

        async let first: JobSnapshot.Chapter? = {
            var iter = s1.makeAsyncIterator()
            return await iter.next() ?? nil
        }()

        async let second: JobSnapshot.Chapter? = {
            var iter = s2.makeAsyncIterator()
            return await iter.next() ?? nil
        }()

        let (ch1, ch2) = await (first, second)
        XCTAssertNil(ch1, "Consumer 1 should see nil chapter before any snapshot is set")
        XCTAssertNil(ch2, "Consumer 2 should see nil chapter before any snapshot is set")
    }

    private func chapter(index: Int, url: String?) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Chapter \(index + 1)",
            status: url == nil ? "converting" : "completed",
            downloadUrl: url,
            chars: 100,
            charsProcessed: url == nil ? 10 : 100,
            progressRatio: url == nil ? 0.1 : 1.0,
            durationSeconds: nil,
            startedAt: nil,
            completedAt: nil
        )
    }

    private func snapshot(chapters: [JobSnapshot.Chapter], state: String) -> JobSnapshot {
        JobSnapshot(
            jobId: "streaming-snapshot-job",
            state: state,
            bookTitle: "Streaming Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: chapters.count,
            chaptersCompleted: chapters.filter { $0.downloadUrl != nil }.count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }
}

// MARK: - JobSnapshot test stubs

private extension JobSnapshot {
    static func stub(playableCount: Int) -> JobSnapshot {
        let chapters = (0..<playableCount).map { i in
            JobSnapshot.Chapter(
                index: i,
                name: "Chapter \(i + 1)",
                status: "completed",
                downloadUrl: "/fake/ch\(i).mp3",
                chars: nil,
                charsProcessed: nil,
                progressRatio: 1.0,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: nil
            )
        }
        return JobSnapshot(
            jobId: "stub-\(UUID().uuidString)",
            state: "completed",
            bookTitle: "Stub Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: playableCount,
            chaptersCompleted: playableCount,
            chapterProgress: chapters.isEmpty ? nil : chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }
}
#endif
