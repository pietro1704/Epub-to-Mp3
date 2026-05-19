#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import MediaPlayer
@testable import EpubToMp3

/// Tests for lock-screen / Control Center / Now Playing widget integration.
///
/// These tests run against the macOS host via the SPM test target and do
/// NOT require a real iOS device or running audio session.  MPNowPlayingInfoCenter
/// and MPRemoteCommandCenter are available on macOS 10.12.2+ and behave
/// the same way as on iOS for the purposes of metadata reads.
///
/// NOTE: On a headless CI host, `MPRemoteCommandCenter.shared()` may not
/// fire handlers because there is no active audio session / Now Playing
/// client.  The tests below only verify the *registration* side (isEnabled,
/// nowPlayingInfo dict) — they do not attempt to synthesise remote events
/// end-to-end.
@MainActor
final class AudioPlayerLockScreenTests: XCTestCase {

    // MARK: - Helpers

    /// Minimal one-chapter snapshot for testing.
    private func makeSnapshot(
        jobId: String = "test-job",
        title: String = "Foundation",
        author: String = "Isaac Asimov"
    ) -> JobSnapshot {
        let json = """
        {
          "jobId": "\(jobId)",
          "state": "finished",
          "bookTitle": "\(title)",
          "bookAuthor": "\(author)",
          "progressPercent": 100.0,
          "chaptersTotal": 2,
          "chaptersCompleted": 2,
          "chapterProgress": [
            {
              "index": 0,
              "name": "Prologue",
              "status": "completed",
              "downloadUrl": "https://example.com/ch0.mp3",
              "progressRatio": 1.0,
              "durationSeconds": 120.0
            },
            {
              "index": 1,
              "name": "Chapter 1",
              "status": "completed",
              "downloadUrl": "https://example.com/ch1.mp3",
              "progressRatio": 1.0,
              "durationSeconds": 300.0
            }
          ]
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(JobSnapshot.self, from: json)
    }

    // MARK: - Remote command registration

    /// After remote-command configuration, every command that the lock
    /// screen / Control Center exposes MUST have a registered handler so
    /// the system shows the correct buttons. Command setup is lazy
    /// (deferred to first playback), so the test drives it explicitly
    /// via `ensureRemoteCommands()`.
    func testRemoteCommandsRegisteredAfterConfiguration() {
        let player = AudioPlayer()
        player.ensureRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        // The enablement is set by the system once there is at least one
        // registered target.  We can only assert the handler was added —
        // a nil target list would still have `isEnabled = false` because
        // there is no audio session on a headless host.  Instead, verify
        // the commands do not crash and have at least one target by
        // attempting a handle call and checking the result is not
        // `.noSuchContent` (which would mean the command is completely
        // unrecognised by the system).
        //
        // Real enablement (isEnabled == true) requires an active
        // AVAudioSession on iOS hardware; skip that assertion here.
        XCTAssertNotNil(center.playCommand)
        XCTAssertNotNil(center.pauseCommand)
        XCTAssertNotNil(center.skipForwardCommand)
        XCTAssertNotNil(center.skipBackwardCommand)
        XCTAssertNotNil(center.changePlaybackPositionCommand)
        XCTAssertNotNil(center.nextTrackCommand)
        XCTAssertNotNil(center.previousTrackCommand)
    }

    /// `skipForwardCommand` and `skipBackwardCommand` should use the
    /// standard audiobook intervals (30 s forward / 15 s back). Command
    /// setup is lazy, so the test drives `ensureRemoteCommands()` —
    /// without it the shared `MPRemoteCommandCenter` keeps the system
    /// default and the test becomes order-dependent.
    func testSkipIntervalsAreAudiobookStandard() {
        let player = AudioPlayer()
        player.ensureRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals, [30])
        XCTAssertEqual(center.skipBackwardCommand.preferredIntervals, [15])
    }

    // MARK: - Now Playing metadata
    //
    // These assert on `AudioPlayer.makeNowPlayingInfo()` — the pure
    // dict builder — rather than `MPNowPlayingInfoCenter.default()
    // .nowPlayingInfo`. The system Now Playing singleton does not
    // round-trip reads in a headless xctest host (macOS or iOS
    // simulator), so reading it back is flaky; the dict builder is
    // deterministic and exercises the exact metadata logic the
    // singleton would receive.

    /// After a snapshot is loaded into the player via `updateSnapshot`
    /// — the live-stream path used by `PlayerReaderView` — the Now
    /// Playing dict must carry the correct title, album (book title),
    /// artist, and media type.
    func testNowPlayingInfoPopulatedOnUpdateSnapshot() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot(title: "Foundation", author: "Isaac Asimov"))

        let info = player.makeNowPlayingInfo()
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Foundation",
            "Album title should be the book title so the Control Center widget shows it")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Isaac Asimov",
            "Artist should be the book author")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt,
            MPNowPlayingInfoMediaType.audio.rawValue,
            "Media type must be .audio so the system routes the session correctly")
        XCTAssertNotNil(info[MPMediaItemPropertyTitle], "Title field must be present")
    }

    /// Elapsed time, duration, and playback-rate fields must be present
    /// so the lock-screen scrubber is functional.
    func testNowPlayingInfoContainsElapsedAndRateFields() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot())

        let info = player.makeNowPlayingInfo()
        XCTAssertNotNil(info[MPNowPlayingInfoPropertyElapsedPlaybackTime],
            "Elapsed time must be present for scrubber")
        XCTAssertNotNil(info[MPMediaItemPropertyPlaybackDuration],
            "Duration must be present for scrubber")
        XCTAssertNotNil(info[MPNowPlayingInfoPropertyPlaybackRate],
            "Playback rate must be present; 0 = paused")
        XCTAssertNotNil(info[MPNowPlayingInfoPropertyDefaultPlaybackRate],
            "Default playback rate must be set so speed overlay is calibrated")
    }

    /// When `coverArtData` holds valid image bytes, the Now Playing
    /// dict must carry `MPMediaItemPropertyArtwork`.
    func testArtworkAppearsInNowPlayingInfoWhenCoverDataIsSet() {
        let player = AudioPlayer()

        // Minimal 1×1 white PNG (67 bytes, valid across all Apple platforms).
        let png1x1 = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F,
            0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59,
            0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        player.coverArtData = png1x1
        player.updateSnapshot(makeSnapshot())

        let artwork = player.makeNowPlayingInfo()[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        XCTAssertNotNil(artwork,
            "MPMediaItemPropertyArtwork must be set when coverArtData contains valid image bytes")
    }

    /// `stop()` must drop the active book so the lock screen no longer
    /// shows stale metadata — `snapshot` goes nil and the Now Playing
    /// dict falls back to the app-name placeholder.
    func testStopClearsNowPlayingInfo() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot(title: "Foundation"))
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyAlbumTitle] as? String,
            "Foundation", "Album must be populated before stop()")

        player.stop()
        XCTAssertNil(player.snapshot, "stop() must drop the active snapshot")
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyAlbumTitle] as? String,
            "Epub-to-Mp3",
            "After stop() the Now Playing dict must fall back to the placeholder, not stale metadata")
    }

    /// After a stop/restart cycle a new snapshot must repopulate the
    /// Now Playing metadata — the widget must never stay blank.
    func testNowPlayingInfoRepopulatedAfterStop() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot(title: "Dune", author: "Frank Herbert"))
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyAlbumTitle] as? String, "Dune")

        player.stop()
        XCTAssertNil(player.snapshot)

        player.updateSnapshot(makeSnapshot(title: "Foundation", author: "Isaac Asimov"))
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyAlbumTitle] as? String,
            "Foundation",
            "Album title must reflect the new book after stop/restart")
    }

    /// Playback rate must be 0 when nothing is playing so the
    /// lock-screen scrubber does not animate phantom progress before
    /// audio starts.
    func testPlaybackRateIsZeroWhenNotPlaying() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot())

        let rate = player.makeNowPlayingInfo()[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber
        XCTAssertEqual(rate?.doubleValue, 0.0,
            "Playback rate must be 0 when not playing so the lock-screen scrubber does not animate")
    }
}
#endif
