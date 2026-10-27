import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class PlayerDismissalDecisionTests: XCTestCase {
    func testCancelledGestureNeverDismissesEvenBeyondBothThresholds() {
        XCTAssertFalse(PlayerDismissalDecision.shouldDismiss(translation: 300, velocity: 1500, cancelled: true))
    }

    func testDistanceOrVelocityCanCommitAnEndedGesture() {
        XCTAssertTrue(PlayerDismissalDecision.shouldDismiss(translation: 121, velocity: 0, cancelled: false))
        XCTAssertTrue(PlayerDismissalDecision.shouldDismiss(translation: 20, velocity: 801, cancelled: false))
    }

    func testThresholdsAndSmallOrUpwardDragsRestoreThePlayer() {
        for values in [(120.0, 800.0), (0, 0), (-200, -1200), (30, 40)] {
            XCTAssertFalse(PlayerDismissalDecision.shouldDismiss(translation: values.0, velocity: values.1, cancelled: false))
        }
    }

    func testInvalidGestureMeasurementsCannotCommitDismissal() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(PlayerDismissalDecision.shouldDismiss(translation: invalid, velocity: 900, cancelled: false))
            XCTAssertFalse(PlayerDismissalDecision.shouldDismiss(translation: 300, velocity: invalid, cancelled: false))
        }
    }
}
