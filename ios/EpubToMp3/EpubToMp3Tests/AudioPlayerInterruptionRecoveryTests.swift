import XCTest
@testable import EpubToMp3

final class AudioPlayerInterruptionRecoveryTests: XCTestCase {
    func testInterruptionBeginPausesOnlyWhenPlaybackWasActive() {
        XCTAssertEqual(
            AudioPlayer.interruptionRecoveryAction(
                interruptionBegan: true,
                shouldResume: false,
                wasPlaying: true
            ),
            .pause
        )
        XCTAssertEqual(
            AudioPlayer.interruptionRecoveryAction(
                interruptionBegan: true,
                shouldResume: false,
                wasPlaying: false
            ),
            .none
        )
    }

    func testInterruptionEndResumesOnlyWhenSystemRequestsResumeAndIntentWasPlaying() {
        XCTAssertEqual(
            AudioPlayer.interruptionRecoveryAction(
                interruptionBegan: false,
                shouldResume: true,
                wasPlaying: true
            ),
            .resume
        )
        XCTAssertEqual(
            AudioPlayer.interruptionRecoveryAction(
                interruptionBegan: false,
                shouldResume: true,
                wasPlaying: false
            ),
            .none
        )
        XCTAssertEqual(
            AudioPlayer.interruptionRecoveryAction(
                interruptionBegan: false,
                shouldResume: false,
                wasPlaying: true
            ),
            .none
        )
    }

    func testRouteChangePausesWhenOldOutputWasRemoved() {
        XCTAssertTrue(AudioPlayer.shouldPauseForRouteChange(reason: AudioPlayer.RouteChangeReason.oldDeviceUnavailable))
        XCTAssertFalse(AudioPlayer.shouldPauseForRouteChange(reason: AudioPlayer.RouteChangeReason.newDeviceAvailable))
        XCTAssertFalse(AudioPlayer.shouldPauseForRouteChange(reason: AudioPlayer.RouteChangeReason.categoryChange))
    }

    func testMediaServicesResetRequiresSessionReconfigurationAndPlaybackRecovery() {
        XCTAssertTrue(AudioPlayer.shouldRecoverFromMediaServicesReset(wasPlaying: true))
        XCTAssertFalse(AudioPlayer.shouldRecoverFromMediaServicesReset(wasPlaying: false))
    }

    func testFailedAudioSessionConfigurationRemainsRetryable() {
        XCTAssertFalse(AudioPlayer.audioSessionConfigurationStateAfterAttempt(succeeded: false))
        XCTAssertTrue(AudioPlayer.audioSessionConfigurationStateAfterAttempt(succeeded: true))
    }

    func testPlaybackStateFollowsQueueRateDuringReconciliation() {
        XCTAssertTrue(AudioPlayer.reconciledIsPlaying(queueRate: 1, currentIsPlaying: false))
        XCTAssertFalse(AudioPlayer.reconciledIsPlaying(queueRate: 0, currentIsPlaying: true))
        XCTAssertFalse(AudioPlayer.reconciledIsPlaying(queueRate: 0, currentIsPlaying: false))
    }

    func testAudioSessionObserversHaveLifecycleOwnership() throws {
        let source = try sourceFile(named: "AudioPlayer.swift")
        XCTAssertTrue(source.contains("interruptionNotification"))
        XCTAssertTrue(source.contains("routeChangeNotification"))
        XCTAssertTrue(source.contains("mediaServicesWereResetNotification"))
        XCTAssertTrue(source.contains("removeObserver"))
    }

    private func sourceFile(named name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Services/\(name)"),
            encoding: .utf8
        )
    }
}
