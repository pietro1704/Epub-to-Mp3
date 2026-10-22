#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
@testable import EpubToMp3

/// Public AudioPlayer timer commands delegate to SleepPlaybackTimer.
/// The dedicated timer tests exercise expiry, fading and cancellation.
final class AudioPlayerSleepTimerTests: XCTestCase {

    // MARK: - setSleepTimer state

    @MainActor
    func testSetSleepTimerPositiveSetsRemaining() {
        let player = AudioPlayer()
        player.setSleepTimer(seconds: 120)
        XCTAssertEqual(player.sleepTimerRemaining, 120, accuracy: 0.5)
    }

    @MainActor
    func testSetSleepTimerZeroCancels() {
        let player = AudioPlayer()
        player.setSleepTimer(seconds: 60)
        player.setSleepTimer(seconds: 0)
        XCTAssertEqual(player.sleepTimerRemaining, 0)
    }

    @MainActor
    func testCancelSleepTimerResetsRemaining() {
        let player = AudioPlayer()
        player.setSleepTimer(seconds: 300)
        player.cancelSleepTimer()
        XCTAssertEqual(player.sleepTimerRemaining, 0)
    }

    @MainActor
    func testStartSleepTimerMinutesConvertsCorrectly() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 5)
        XCTAssertEqual(player.sleepTimerRemaining, 300, accuracy: 1.0)
    }

    @MainActor
    func testStartSleepTimerZeroMinutesCancels() {
        let player = AudioPlayer()
        player.startSleepTimer(minutes: 10)
        player.startSleepTimer(minutes: 0)
        XCTAssertEqual(player.sleepTimerRemaining, 0)
    }

}
#endif
