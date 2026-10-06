import XCTest
@testable import EpubToMp3

final class PlaybackClockTests: XCTestCase {
    @MainActor
    func testUpdatesPublishAsOneSnapshot() {
        let clock = PlaybackClock()
        XCTAssertEqual(clock.snapshot, .zero)

        clock.update(positionSeconds: 12, durationSeconds: 120, sleepTimerRemaining: 300)

        XCTAssertEqual(
            clock.snapshot,
            PlaybackClock.Snapshot(
                positionSeconds: 12,
                durationSeconds: 120,
                sleepTimerRemaining: 300
            )
        )
    }

    @MainActor
    func testPartialUpdatePreservesOtherFields() {
        let clock = PlaybackClock()
        clock.update(positionSeconds: 12, durationSeconds: 120, sleepTimerRemaining: 300)

        clock.update(positionSeconds: 24)

        XCTAssertEqual(clock.positionSeconds, 24)
        XCTAssertEqual(clock.durationSeconds, 120)
        XCTAssertEqual(clock.sleepTimerRemaining, 300)
    }

    @MainActor
    func testResetReturnsToZero() {
        let clock = PlaybackClock()
        clock.update(positionSeconds: 24, durationSeconds: 120, sleepTimerRemaining: 300)

        clock.reset()

        XCTAssertEqual(clock.snapshot, .zero)
    }
}
