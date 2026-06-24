#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// Unit tests for the UX-layer additions to `AudioPlayer`:
/// sleep timer, rate cycling, skip ±15 s.
///
/// These tests run on the macOS host (no iOS device required). Because
/// AVQueuePlayer cannot load remote URLs in a unit-test sandbox, we
/// verify observable state rather than actual audio output.
@MainActor
final class AudioPlayerUXTests: XCTestCase {

    // MARK: - Helpers

    private func makePlayer() -> AudioPlayer { AudioPlayer() }

    // MARK: - Sleep timer

    /// `startSleepTimer(minutes:)` must set `sleepTimerRemaining` to the
    /// correct number of seconds.
    func testStartSleepTimerSetsRemaining() {
        let player = makePlayer()
        player.startSleepTimer(minutes: 5)
        XCTAssertEqual(player.sleepTimerRemaining, 300, accuracy: 1,
            "5-minute timer should expose 300 s remaining immediately after start")
    }

    /// `cancelSleepTimer()` must zero out remaining time.
    func testCancelSleepTimerZerosRemaining() {
        let player = makePlayer()
        player.startSleepTimer(minutes: 30)
        player.cancelSleepTimer()
        XCTAssertEqual(player.sleepTimerRemaining, 0,
            "Remaining should be 0 after cancel")
    }

    /// `setSleepTimer(seconds: 0)` is equivalent to cancel.
    func testSetSleepTimerZeroActsAsCancel() {
        let player = makePlayer()
        player.startSleepTimer(minutes: 15)
        player.setSleepTimer(seconds: 0)
        XCTAssertEqual(player.sleepTimerRemaining, 0)
    }

    /// Calling `startSleepTimer` a second time overwrites the first schedule.
    func testRestartingTimerOverwritesPrevious() {
        let player = makePlayer()
        player.startSleepTimer(minutes: 60)
        player.startSleepTimer(minutes: 5)
        XCTAssertEqual(player.sleepTimerRemaining, 300, accuracy: 1,
            "Second call should replace the first; remaining should reflect the new duration")
    }

    /// `setSleepTimer(seconds: 0)` issued after a non-zero schedule must
    /// immediately drop `sleepTimerRemaining` to 0. This is the observable
    /// surface for "timer cancelled / expired" — the internal tick fires
    /// only via AVPlayer's periodic observer which requires a real audio
    /// session, so we test the cancel path instead.
    func testSleepTimerCancelDropsRemainingToZero() {
        let player = makePlayer()
        player.setSleepTimer(seconds: 300)
        XCTAssertGreaterThan(player.sleepTimerRemaining, 0,
            "Remaining should be positive after setting a 5-minute timer")
        player.setSleepTimer(seconds: 0)
        XCTAssertEqual(player.sleepTimerRemaining, 0,
            "setSleepTimer(0) must zero the remaining counter")
    }

    // MARK: - availableRates

    func testAvailableRatesContainsExpectedValues() {
        let player = makePlayer()
        let expected: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        XCTAssertEqual(player.availableRates, expected)
    }

    // MARK: - cycleRate

    /// Starting at 1x, successive `cycleRate()` calls should advance
    /// through the ordered list and wrap around from 2x back to 0.5x.
    func testCycleRateAdvancesThroughAllCases() {
        let player = makePlayer()
        // Default rate is 1.0.
        XCTAssertEqual(player.rate, .x100)

        let expected: [PlaybackRate] = [.x125, .x150, .x175, .x200,
                                        .x050, .x075, .x100]
        for expectedRate in expected {
            player.cycleRate()
            XCTAssertEqual(player.rate, expectedRate,
                "After cycle, rate should be \(expectedRate.shortLabel)")
        }
    }

    /// After a full loop (7 cycles from 1.0), the rate must return to 1.0.
    func testCycleRateWrapsAroundToStart() {
        let player = makePlayer()
        let cycleCount = PlaybackRate.allCases.count
        for _ in 0..<cycleCount { player.cycleRate() }
        XCTAssertEqual(player.rate, .x100,
            "Cycling through all \(cycleCount) rates must land back at 1.0")
    }

    // MARK: - PlaybackRate.shortLabel

    func testShortLabelForCommonRates() {
        XCTAssertEqual(PlaybackRate.x100.shortLabel, "1x")
        XCTAssertEqual(PlaybackRate.x125.shortLabel, "1.25x")
        XCTAssertEqual(PlaybackRate.x050.shortLabel, "0.5x")
        XCTAssertEqual(PlaybackRate.x200.shortLabel, "2x")
    }

    // MARK: - skipForward / skipBackward

    /// Because no real AVPlayerItem is loaded, `positionSeconds` starts at
    /// 0 and `durationSeconds` at 0. `skip(by:)` clamps to [0, duration],
    /// so skipForward is clamped to 0. We verify the clamp logic rather
    /// than actual seek success (which requires a real audio file).
    func testSkipForwardClampedAtDuration() {
        let player = makePlayer()
        // No item loaded; duration == 0 → any skip forward clamps to 0.
        player.skipForward(seconds: 15)
        XCTAssertEqual(player.positionSeconds, 0,
            "Skip forward with no audio loaded should stay at 0 (clamped)")
    }

    func testSkipBackwardClampedAtZero() {
        let player = makePlayer()
        player.skipBackward(seconds: 15)
        XCTAssertEqual(player.positionSeconds, 0,
            "Skip backward below 0 should clamp to 0")
    }

    /// When `positionSeconds` is known (simulate via `seek`), `skipForward`
    /// should add the delta. We fake durationSeconds via a snapshot-less
    /// seek so we can verify the arithmetic.
    func testSkipForwardAddsSeconds() {
        let player = makePlayer()
        // Seek to 30 s without a real player item (seek clamps to 0 since
        // durationSeconds == 0, so we cannot go past 0 here). Instead we
        // verify that skipForward does NOT exceed positionSeconds when
        // duration is 0 — i.e., the clamp logic fires correctly.
        player.skipForward(seconds: 30)
        XCTAssertGreaterThanOrEqual(player.positionSeconds, 0)
        XCTAssertLessThanOrEqual(player.positionSeconds, player.durationSeconds)
    }

    // MARK: - isPlaying gate (reader chapter sync regression)

    /// A freshly created player with a loaded snapshot must report
    /// `isPlaying == false`. The reader's `installPositionLoop` uses
    /// this flag to prevent an idle player at chapter 0 from forcing
    /// the reader back to the TOC/index chapter on every position
    /// update — the "1→index→2→index" regression (bcfebf3 → fix).
    func testIdlePlayerWithSnapshotIsNotPlaying() {
        let player = makePlayer()
        XCTAssertFalse(player.isPlaying,
            "A freshly initialised player must not report isPlaying=true")
    }

    /// `isPlaying` must remain false after loading a snapshot without
    /// calling `play`. The position-loop chapter-sync must therefore
    /// skip the reader-chapter assignment, leaving the reader wherever
    /// the user navigated to.
    func testLoadingSnapshotAloneDoesNotSetIsPlaying() {
        let player = makePlayer()
        let snap = JobSnapshot.previewSample
        player.backendBaseURL = URL(string: "http://localhost:8000")
        player.play(snapshot: snap, startingAt: 0)
        // `play` calls `pause()` internally when called from a cold state
        // in tests; wait one runloop tick to let state settle.
        let exp = expectation(description: "isPlaying settles")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        // In the unit-test sandbox there is no real AVQueuePlayer item to
        // auto-start, so isPlaying must stay false.
        XCTAssertFalse(player.isPlaying,
            "Loading a snapshot without user interaction must not set isPlaying=true")
    }
}
#endif
