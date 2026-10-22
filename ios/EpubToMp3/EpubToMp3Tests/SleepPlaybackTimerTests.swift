import AVFoundation
import XCTest
@testable import EpubToMp3

final class SleepPlaybackTimerTests: XCTestCase {
    @MainActor
    func testExpiryUsesWallClockWithoutChangingTransport() async {
        let clock = PlaybackClock()
        clock.update(positionSeconds: 12, durationSeconds: 80)
        var date = Date(timeIntervalSince1970: 100)
        var pauses = 0
        let timer = SleepPlaybackTimer(clock: clock, now: { date })
        timer.set(seconds: 10)
        date = date.addingTimeInterval(4)
        XCTAssertNil(timer.tick(player: nil, pause: { pauses += 1 }))
        XCTAssertEqual(clock.sleepTimerRemaining, 6)
        date = date.addingTimeInterval(6)
        let task = timer.tick(player: nil, pause: { pauses += 1 })
        await task?.value
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(clock.snapshot, .init(positionSeconds: 12, durationSeconds: 80, sleepTimerRemaining: 0))
        XCTAssertNil(timer.tick(player: nil, pause: { pauses += 1 }))
        XCTAssertEqual(pauses, 1)
    }

    @MainActor
    func testFadeReachesZeroBeforePauseAndRestoresVolume() async {
        let clock = PlaybackClock()
        var date = Date(timeIntervalSince1970: 100)
        let player = AVQueuePlayer()
        player.volume = 0.8
        var volumes: [Float] = []
        var delays: [UInt64] = []
        var pauseVolumes: [Float] = []
        let timer = SleepPlaybackTimer(clock: clock, now: { date }, sleep: { delay in
            volumes.append(player.volume)
            delays.append(delay)
        })
        timer.set(seconds: 1)
        date = date.addingTimeInterval(1)
        let task = timer.tick(player: player, pause: { pauseVolumes.append(player.volume) })
        // Repeated observer ticks must not spawn a second fade.
        timer.tick(player: player, pause: { XCTFail("Duplicate fade") })
        await task?.value
        XCTAssertEqual(volumes.count, 21)
        XCTAssertEqual(volumes.first, 0.8)
        XCTAssertEqual(volumes.last, 0)
        XCTAssertEqual(pauseVolumes, [0])
        XCTAssertEqual(Set(delays), [500_000_000])
        XCTAssertEqual(player.volume, 0.8)
    }

    @MainActor
    func testCancellationDuringFadeRestoresVolumeWithoutPausing() async {
        var date = Date(timeIntervalSince1970: 100)
        let player = AVQueuePlayer()
        player.volume = 0.7
        var steps = 0
        var timer: SleepPlaybackTimer!
        timer = SleepPlaybackTimer(clock: PlaybackClock(), now: { date }, sleep: { _ in
            steps += 1
            if steps == 2 { timer.set(seconds: 0) }
            try Task.checkCancellation()
        })
        timer.set(seconds: 1)
        date = date.addingTimeInterval(1)
        let task = timer.tick(player: player, pause: { XCTFail("Cancelled fade paused playback") })
        await task?.value
        XCTAssertEqual(steps, 2)
        XCTAssertEqual(player.volume, 0.7)
        XCTAssertNil(timer.tick(player: player, pause: {}))
    }

    @MainActor
    func testFailedSleepRestoresVolumeAndAllowsAnotherTimer() async {
        enum Failure: Error { case sleep }
        var date = Date(timeIntervalSince1970: 100)
        let player = AVQueuePlayer()
        player.volume = 0.6
        var steps = 0
        let timer = SleepPlaybackTimer(clock: PlaybackClock(), now: { date }, sleep: { _ in
            steps += 1
            throw Failure.sleep
        })
        for _ in 0..<2 {
            timer.set(seconds: 1)
            date = date.addingTimeInterval(1)
            let task = timer.tick(player: player, pause: { XCTFail("Failed fade paused playback") })
            await task?.value
        }
        XCTAssertEqual(steps, 2)
        XCTAssertEqual(player.volume, 0.6)
    }

    @MainActor
    func testReplacingArmedTimerUsesLatestDeadlineAndCancellingIsIsolated() {
        let clock = PlaybackClock()
        var date = Date(timeIntervalSince1970: 100)
        let timer = SleepPlaybackTimer(clock: clock, now: { date })
        let otherClock = PlaybackClock()
        let otherTimer = SleepPlaybackTimer(clock: otherClock, now: { date })
        otherTimer.set(seconds: 90)
        timer.set(seconds: 1)
        timer.set(seconds: 30)
        date = date.addingTimeInterval(2)
        XCTAssertNil(timer.tick(player: nil, pause: { XCTFail("Old deadline fired") }))
        XCTAssertEqual(clock.sleepTimerRemaining, 28)
        timer.set(seconds: -1)
        XCTAssertEqual(clock.sleepTimerRemaining, 0)
        XCTAssertEqual(otherClock.sleepTimerRemaining, 90)
        XCTAssertNil(timer.tick(player: nil, pause: { XCTFail("Cancelled deadline fired") }))
    }
}
