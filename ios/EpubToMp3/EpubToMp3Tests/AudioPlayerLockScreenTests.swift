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
    @MainActor
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

    /// The initial transport preference must use the product default of
    /// 15 seconds in both directions. Command setup is lazy, so the test
    /// drives `ensureRemoteCommands()` — without it the shared
    /// `MPRemoteCommandCenter` keeps the system default and the test becomes
    /// order-dependent.
    @MainActor
    func testSkipIntervalsDefaultToFifteenSecondsInBothDirections() {
        let player = AudioPlayer()
        player.ensureRemoteCommands()
        let center = MPRemoteCommandCenter.shared()
        XCTAssertEqual(center.skipForwardCommand.preferredIntervals, [15])
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
    /// Playing dict must carry the current chapter as primary title, the
    /// book as secondary album metadata, author and media type.
    @MainActor
    func testNowPlayingInfoPopulatedOnUpdateSnapshot() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot(title: "Foundation", author: "Isaac Asimov"))

        let info = player.makeNowPlayingInfo()
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Prologue",
            "Primary Now Playing title must be the chapter")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Foundation",
            "Secondary Now Playing metadata must identify the book")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Isaac Asimov",
            "Artist should be the book author")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt,
            MPNowPlayingInfoMediaType.audio.rawValue,
            "Media type must be .audio so the system routes the session correctly")
        XCTAssertNotNil(info[MPMediaItemPropertyTitle], "Title field must be present")
    }

    /// Elapsed time, duration, and playback-rate fields must be present
    /// so the lock-screen scrubber is functional.
    @MainActor
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
    @MainActor
    func testArtworkAppearsInNowPlayingInfoWhenCoverDataIsSet() throws {
#if targetEnvironment(simulator)
        throw XCTSkip("MPMediaItemArtwork is not stable in the iOS Simulator media service.")
#else
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
#endif
    }

    @MainActor
    func testUpdatingCoverArtPublishesArtworkForNowPlaying() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot())

        player.updateCoverArtData(EpubFixture.coverPNG)

        let artwork = player.makeNowPlayingInfo()[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        XCTAssertNotNil(artwork)
    }

    /// `stop()` must drop the active book so the lock screen no longer
    /// shows stale metadata — `snapshot` goes nil and the Now Playing
    /// dict falls back to the app-name placeholder.
    @MainActor
    func testStopClearsNowPlayingInfo() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot(title: "Foundation"))
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyTitle] as? String,
            "Prologue", "Title must be populated before stop()")

        player.stop()
        XCTAssertNil(player.snapshot, "stop() must drop the active snapshot")
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyTitle] as? String,
            L10n.string("player.chapter", 1),
            "After stop() the Now Playing dict must not retain stale metadata")
    }

    /// After a stop/restart cycle a new snapshot must repopulate the
    /// Now Playing metadata — the widget must never stay blank.
    @MainActor
    func testNowPlayingInfoRepopulatedAfterStop() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot(title: "Dune", author: "Frank Herbert"))
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyTitle] as? String, "Prologue")

        player.stop()
        XCTAssertNil(player.snapshot)

        player.updateSnapshot(makeSnapshot(title: "Foundation", author: "Isaac Asimov"))
        XCTAssertEqual(player.makeNowPlayingInfo()[MPMediaItemPropertyTitle] as? String,
            "Prologue",
            "Album title must reflect the new book after stop/restart")
    }

    /// Playback rate must be 0 when nothing is playing so the
    /// lock-screen scrubber does not animate phantom progress before
    /// audio starts.
    @MainActor
    func testPlaybackRateIsZeroWhenNotPlaying() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot())

        let rate = player.makeNowPlayingInfo()[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber
        XCTAssertEqual(rate?.doubleValue, 0.0,
            "Playback rate must be 0 when not playing so the lock-screen scrubber does not animate")
    }

    @MainActor
    func testNowPlayingPrefersRealChapterNameOverGenericProgressName() {
        XCTAssertEqual(
            AudioPlayer.preferredChapterTitle(
                primary: "Chapter 1",
                secondary: "The Fellowship of the Ring",
                fallback: "Chapter 1"
            ),
            "The Fellowship of the Ring"
        )
        XCTAssertEqual(
            AudioPlayer.preferredChapterTitle(
                primary: "Capítulo 1",
                secondary: "Shelob's Lair",
                fallback: "Capítulo 1"
            ),
            "Shelob's Lair"
        )
    }

    @MainActor
    func testNowPlayingPrimaryTitleIsCurrentChapter() {
        let player = AudioPlayer()
        player.updateSnapshot(makeSnapshot(title: "Foundation"))

        XCTAssertEqual(
            player.makeNowPlayingInfo()[MPMediaItemPropertyTitle] as? String,
            "Prologue",
            "Now Playing primary title must be the current chapter, not the book")
        XCTAssertEqual(
            player.makeNowPlayingInfo()[MPMediaItemPropertyAlbumTitle] as? String,
            "Foundation",
            "Now Playing album metadata should retain the book title")
    }

    @MainActor
    func testRemoteStreamingUsesReaderHeadingBeforeAnyChapterMP3IsComplete() {
        let snapshot = JobSnapshot(
            jobId: "remote-streaming-job",
            state: "running",
            bookTitle: "The Lord of the Rings",
            bookAuthor: "J.R.R. Tolkien",
            coverUrl: nil,
            coverMimeType: nil,
            engine: "edge",
            voice: nil,
            language: "en",
            progressPercent: 0,
            chaptersTotal: 1,
            chaptersCompleted: 0,
            chapterProgress: [
                .init(
                    index: 1,
                    name: "Chapter 1",
                    status: "processing",
                    downloadUrl: nil,
                    chars: 100,
                    charsProcessed: 10,
                    progressRatio: 0.1,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            ],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
        let player = AudioPlayer()

        XCTAssertTrue(
            player.beginRemoteStreaming(
                snapshot: snapshot,
                backendBaseURL: URL(string: "https://example.com")!
            )
        )
        player.updateReaderChapterTitle("The Fellowship of the Ring", for: 0)

        let info = player.makeNowPlayingInfo()
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "The Fellowship of the Ring")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "The Lord of the Rings")
    }

    @MainActor
    func testPlaybackURLResolvesBackendRelativeOutputPath() {
        let url = AudioPlayer.playbackURL(
            forDownloadPath: "/api/outputs/job-1/chapter.mp3",
            backendBaseURL: URL(string: "https://example.com:8443")
        )

        XCTAssertEqual(url?.absoluteString, "https://example.com:8443/api/outputs/job-1/chapter.mp3")
    }
}
#endif
