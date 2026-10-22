#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerStreamingTests {
    @MainActor
    func testFirstSegmentReadyFalseInitially() {
        let player = AudioPlayer()
        XCTAssertFalse(player.firstSegmentReady,
            "firstSegmentReady must be false before any segment arrives")
    }

    @MainActor
    func testFirstSegmentReadyTrueAfterFirstEnqueue() {
        let player = AudioPlayer()
        let mp3 = fakeMP3()
        player.enqueueSegment(data: mp3, chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstSegmentReady,
            "firstSegmentReady must flip to true after the first enqueueSegment call")
    }

    @MainActor
    func testFirstSegmentReadyIsLatch() {
        let player = AudioPlayer()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 1)
        XCTAssertTrue(player.firstSegmentReady,
            "firstSegmentReady must remain true after multiple segments")
    }

    /// Regression: `enqueueSegment` used to call `queue.play()` + flip
    /// `isPlaying = true` the moment the first chunk arrived from SSE,
    /// even though the user had never tapped Play. Media must never
    /// auto-start without explicit user intent (in-app Play button,
    /// lock-screen, or widget remote command).
    @MainActor
    func testEnqueueSegmentDoesNotAutoStartPlayback() {
        let player = AudioPlayer()
        XCTAssertFalse(player.isPlaying, "fresh AudioPlayer must be paused")
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertFalse(player.isPlaying,
            "enqueueSegment must NOT auto-start playback — only resume()/togglePlayPause() may")
    }

    /// A Listen action is explicit media intent even when the conversion has
    /// not produced its first segment yet. The queued intent must carry over
    /// so the first arriving segment starts without a second tap.
    @MainActor
    func testResumeBeforeFirstSegmentStartsStreamingPlayback() {
        let player = AudioPlayer()
        player.resume()
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.isPlaying,
                      "A queued explicit Listen action must start the first streamed segment")
    }

    @MainActor
    func testFirstChapterReadyAlsoSetAfterFirstSegment() {
        let player = AudioPlayer()
        XCTAssertFalse(player.firstChapterReady)
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertTrue(player.firstChapterReady,
            "enqueueSegment must also set firstChapterReady so MiniPlayerBar shows play/pause")
    }

    @MainActor
    func testIsLoadingFalseAfterFirstSegmentArrives() {
        let player = AudioPlayer()
        player.isConverting = true
        // isLoading = isConverting && !firstChapterReady; after a segment
        // firstChapterReady becomes true, so isLoading must be false.
        player.enqueueSegment(data: fakeMP3(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertFalse(player.isLoading,
            "isLoading must be false once the first segment is enqueued")
    }

    @MainActor
    func testEmptyDataIsIgnored() {
        let player = AudioPlayer()
        player.enqueueSegment(data: Data(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertFalse(player.firstSegmentReady,
            "Empty data must not trigger firstSegmentReady")
    }

    @MainActor
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
}
#endif
