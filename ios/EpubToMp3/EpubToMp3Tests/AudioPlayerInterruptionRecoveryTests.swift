import XCTest
@testable import EpubToMp3

final class AudioPlayerInterruptionRecoveryTests: XCTestCase {
    func testInterruptionBeginPausesOnlyWhenPlaybackWasActive() {
        XCTAssertEqual(
            PlaybackSystemSession.interruptionRecoveryAction(
                interruptionBegan: true,
                shouldResume: false,
                wasPlaying: true
            ),
            .pause
        )
        XCTAssertEqual(
            PlaybackSystemSession.interruptionRecoveryAction(
                interruptionBegan: true,
                shouldResume: false,
                wasPlaying: false
            ),
            .none
        )
    }

    func testInterruptionEndResumesOnlyWhenSystemRequestsResumeAndIntentWasPlaying() {
        XCTAssertEqual(
            PlaybackSystemSession.interruptionRecoveryAction(
                interruptionBegan: false,
                shouldResume: true,
                wasPlaying: true
            ),
            .resume
        )
        XCTAssertEqual(
            PlaybackSystemSession.interruptionRecoveryAction(
                interruptionBegan: false,
                shouldResume: true,
                wasPlaying: false
            ),
            .none
        )
        XCTAssertEqual(
            PlaybackSystemSession.interruptionRecoveryAction(
                interruptionBegan: false,
                shouldResume: false,
                wasPlaying: true
            ),
            .none
        )
    }

    func testRouteChangePausesWhenOldOutputWasRemoved() {
        XCTAssertTrue(PlaybackSystemSession.shouldPauseForRouteChange(reason: AudioPlayer.RouteChangeReason.oldDeviceUnavailable))
        XCTAssertFalse(PlaybackSystemSession.shouldPauseForRouteChange(reason: AudioPlayer.RouteChangeReason.newDeviceAvailable))
        XCTAssertFalse(PlaybackSystemSession.shouldPauseForRouteChange(reason: AudioPlayer.RouteChangeReason.categoryChange))
    }

    func testMediaServicesResetRequiresSessionReconfigurationAndPlaybackRecovery() {
        XCTAssertTrue(PlaybackSystemSession.shouldRecoverFromMediaServicesReset(wasPlaying: true))
        XCTAssertFalse(PlaybackSystemSession.shouldRecoverFromMediaServicesReset(wasPlaying: false))
    }

    func testFailedAudioSessionConfigurationRemainsRetryable() {
        XCTAssertFalse(PlaybackSystemSession.audioSessionConfigurationStateAfterAttempt(succeeded: false))
        XCTAssertTrue(PlaybackSystemSession.audioSessionConfigurationStateAfterAttempt(succeeded: true))
    }

    func testPlaybackStateFollowsQueueRateDuringReconciliation() {
        XCTAssertTrue(PlaybackSystemSession.reconciledIsPlaying(queueRate: 1, currentIsPlaying: false))
        XCTAssertFalse(PlaybackSystemSession.reconciledIsPlaying(queueRate: 0, currentIsPlaying: true))
        XCTAssertFalse(PlaybackSystemSession.reconciledIsPlaying(queueRate: 0, currentIsPlaying: false))
    }

    @MainActor
    func testAudioSessionObserversHaveLifecycleOwnership() async {
        let center = NotificationCenter()
        let object = NSObject()
        let unrelated = NSObject()
        let names = PlaybackAudioSessionObservation.Names(
            interruption: .init("test.interruption"), routeChange: .init("test.route"),
            mediaServicesReset: .init("test.reset"), interruptionTypeKey: "type",
            interruptionOptionsKey: "options", routeChangeReasonKey: "reason")
        var owner: PlaybackAudioSessionObservation? = .init(center: center)
        var interruptions: [(UInt?, UInt)] = []
        var routes: [Int?] = []
        var resets = 0
        func install() {
            owner?.install(names: names, object: object,
                interruption: { interruptions.append(($0, $1)) },
                routeChange: { routes.append($0) }, reset: { resets += 1 })
        }
        install()
        install() // Session recovery cannot duplicate a live subscription.
        center.post(name: names.interruption, object: unrelated,
                    userInfo: ["type": NSNumber(value: 99)])
        XCTAssertTrue(interruptions.isEmpty, "Another audio session cannot emit our intent")
        center.post(name: names.interruption, object: object,
                    userInfo: ["type": NSNumber(value: 1), "options": NSNumber(value: 2)])
        center.post(name: names.routeChange, object: object,
                    userInfo: ["reason": NSNumber(value: 3)])
        center.post(name: names.mediaServicesReset, object: object)
        await Task { @MainActor in }.value
        XCTAssertEqual(interruptions.count, 1)
        XCTAssertEqual(interruptions.first?.0, 1)
        XCTAssertEqual(interruptions.first?.1, 2)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes.first!, 3)
        XCTAssertEqual(resets, 1)

        // Invalidation cancels an already queued reset and all registrations.
        center.post(name: names.mediaServicesReset, object: object)
        owner?.invalidate()
        await Task { @MainActor in }.value
        XCTAssertEqual(resets, 1)
        center.post(name: names.routeChange, object: object)
        XCTAssertEqual(routes.count, 1)
        install()
        center.post(name: names.routeChange, object: object)
        XCTAssertEqual(routes.count, 2, "A new configuration must be observable again")
        XCTAssertNil(routes.last!)

        weak var releasedOwner = owner
        center.post(name: names.mediaServicesReset, object: object)
        owner = nil
        XCTAssertNil(releasedOwner, "NotificationCenter must not retain its owner")
        await Task { @MainActor in }.value
        center.post(name: names.interruption, object: object)
        center.post(name: names.routeChange, object: object)
        XCTAssertEqual(interruptions.count, 1)
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(resets, 1)
    }
}
