#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerStreamingTests {
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
}
#endif
