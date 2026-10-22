#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerDivergenceTests {
    @MainActor
    func testStopCancelsReaderPageSeekBeforeDurationArrives() async throws {
        let player = makePlayer()
        defer { player.stop() }
        let jobID = "cancelled-reader-\(UUID().uuidString)"
        let url = try readerAudioFixture()
        player.setSnapshot(try pendingReaderSnapshot(jobID: jobID))
        player.startFromReaderPage(0, sentenceOffsetRatio: 0.5)
        XCTAssertEqual(player.pendingNavigation?.jobID, jobID)
        XCTAssertTrue(player.isSeeking)
        player.stop()
        XCTAssertNil(player.pendingNavigation, "Stop must synchronously cancel the public page request")
        player.updateSnapshot(try playableReaderSnapshot(jobID: jobID, url: url))
        try await waitForReaderState("cancelled request's late chapter") { player.durationSeconds > 0 }
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isSeeking)
        XCTAssertEqual(player.positionSeconds, 0, accuracy: 0.05,
                       "A late asset must not resurrect a cancelled page seek")
    }

    @MainActor
    func testReaderPageSeekCannotCrossJobsAtTheSameChapterIndex() async throws {
        let player = makePlayer()
        defer { player.stop() }
        let originalJob = "reader-a-\(UUID().uuidString)"
        let nextJob = "reader-b-\(UUID().uuidString)"
        let url = try readerAudioFixture()
        player.setSnapshot(try pendingReaderSnapshot(jobID: originalJob))
        player.startFromReaderPage(0, sentenceOffsetRatio: 0.5)
        XCTAssertEqual(player.pendingNavigation?.jobID, originalJob)
        player.updateSnapshot(try pendingReaderSnapshot(jobID: nextJob))
        XCTAssertNil(player.pendingNavigation, "Another job must discard the request before audio arrives")
        player.updateSnapshot(try playableReaderSnapshot(jobID: nextJob, url: url))
        try await waitForReaderState("new book's duration") { player.durationSeconds > 0 }
        XCTAssertEqual(player.snapshot?.jobId, nextJob)
        XCTAssertEqual(player.currentChapterIndex, 0)
        XCTAssertEqual(player.positionSeconds, 0, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
    }

    /// The public page request survives refresh, uses real asset duration, and is consumed once.
    @MainActor
    func testPendingProportionalSeekAppliedOnceDurationLands() async throws {
        let player = makePlayer()
        defer { player.stop() }
        let jobID = "delayed-reader-\(UUID().uuidString)"
        let url = try readerAudioFixture()
        player.setSnapshot(try pendingReaderSnapshot(jobID: jobID))
        player.startFromReaderPage(0, sentenceOffsetRatio: 0.5)
        let request = try XCTUnwrap(player.pendingNavigation)
        player.pause()
        player.updateSnapshot(try pendingReaderSnapshot(jobID: jobID))
        XCTAssertEqual(player.pendingNavigation, request,
                       "A same-job refresh must retain the same navigation request")
        player.updateSnapshot(try playableReaderSnapshot(jobID: jobID, url: url))
        try await waitForReaderState("duration-based page seek") {
            !player.isSeeking && player.pendingNavigation == nil && abs(player.positionSeconds - 5) < 0.1
        }
        XCTAssertEqual(player.positionSeconds, 5, accuracy: 0.1)
        XCTAssertFalse(player.isPlaying, "Arrival must preserve Pause while waiting")
        player.seek(to: 2)
        try await waitForReaderState("replacement seek") { !player.isSeeking && abs(player.positionSeconds - 2) < 0.1 }
        player.updateSnapshot(try playableReaderSnapshot(jobID: jobID, url: url))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(player.positionSeconds, 2, accuracy: 0.1,
                       "A consumed page request must not reapply on refresh")
    }

    @MainActor
    func testPendingReaderPageSeekSurvivesTheFirstPlayableSnapshot() async throws {
        let player = makePlayer()
        defer { player.stop() }
        let jobID = "first-asset-\(UUID().uuidString)"
        let url = try readerAudioFixture()
        player.setSnapshot(try pendingReaderSnapshot(jobID: jobID))
        player.startFromReaderPage(0, sentenceOffsetRatio: 0.5)
        XCTAssertEqual(player.pendingNavigation?.jobID, jobID)
        player.pause()
        player.updateSnapshot(try playableReaderSnapshot(jobID: jobID, url: url))
        try await waitForReaderState("first file's reader-page seek") {
            !player.isSeeking && player.pendingNavigation == nil && abs(player.positionSeconds - 5) < 0.1
        }
        XCTAssertEqual(player.testHook_playbackChapterCount(), 1)
        XCTAssertEqual((player.testHook_currentPlayerItem()?.asset as? AVURLAsset)?.url, url)
        XCTAssertEqual(player.positionSeconds, 5, accuracy: 0.1)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testPendingReaderPageSeekDoesNotSurviveFirstSnapshotFromAnotherJob() async throws {
        let player = makePlayer()
        defer { player.stop() }
        let previousJob = "previous-\(UUID().uuidString)"
        let nextJob = "new-\(UUID().uuidString)"
        let url = try readerAudioFixture()
        player.setSnapshot(try pendingReaderSnapshot(jobID: previousJob))
        player.startFromReaderPage(0, sentenceOffsetRatio: 0.5)
        XCTAssertEqual(player.pendingNavigation?.jobID, previousJob)
        player.updateSnapshot(try playableReaderSnapshot(jobID: nextJob, url: url))
        XCTAssertNil(player.pendingNavigation)
        try await waitForReaderState("different book's first file") { player.durationSeconds > 0 }
        XCTAssertEqual(player.snapshot?.jobId, nextJob)
        XCTAssertEqual(player.positionSeconds, 0, accuracy: 0.05)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testInvalidFirstReaderAssetCancelsPendingPageSeek() async throws {
        let player = makePlayer()
        defer { player.stop() }
        let jobID = "invalid-asset-\(UUID().uuidString)"
        let url = try readerAudioFixture(valid: false)
        player.setSnapshot(try pendingReaderSnapshot(jobID: jobID))
        player.startFromReaderPage(0, sentenceOffsetRatio: 0.5)
        XCTAssertEqual(player.pendingNavigation?.jobID, jobID)
        player.updateSnapshot(try playableReaderSnapshot(jobID: jobID, url: url))
        try await waitForReaderState("invalid asset cancellation") { player.pendingNavigation == nil && !player.isSeeking }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.positionSeconds, 0)
    }
}
#endif
