import XCTest
@testable import EpubToMp3

final class AdaptiveEdgeConcurrencyPolicyTests: XCTestCase {
    func testExperimentalWifiPolicyPrioritizesFirstAudioThenUsesThreeWorkers() {
        let policy = AdaptiveEdgeConcurrencyPolicy.resolve(
            automaticModeEnabled: true,
            maxPerformanceRequested: false,
            connectivity: .wifi,
            isLowPowerModeEnabled: false,
            thermalState: .nominal,
            recentEdgeFailures: 0
        )

        XCTAssertEqual(policy, .hybrid(maxConcurrentBackfillChunks: 3))
    }

    func testCellularAndDevicePressureStaySerial() {
        XCTAssertEqual(
            AdaptiveEdgeConcurrencyPolicy.resolve(
                automaticModeEnabled: true,
                maxPerformanceRequested: false,
                connectivity: .cellular,
                isLowPowerModeEnabled: false,
                thermalState: .nominal,
                recentEdgeFailures: 0
            ),
            .serial
        )
        XCTAssertEqual(
            AdaptiveEdgeConcurrencyPolicy.resolve(
                automaticModeEnabled: true,
                maxPerformanceRequested: false,
                connectivity: .wifi,
                isLowPowerModeEnabled: true,
                thermalState: .nominal,
                recentEdgeFailures: 0
            ),
            .serial
        )
        XCTAssertEqual(
            AdaptiveEdgeConcurrencyPolicy.resolve(
                automaticModeEnabled: true,
                maxPerformanceRequested: false,
                connectivity: .wifi,
                isLowPowerModeEnabled: false,
                thermalState: .serious,
                recentEdgeFailures: 0
            ),
            .serial
        )
    }

    func testFailuresReduceTheHybridBackfillLimitWithoutInterruptingFirstAudio() {
        XCTAssertEqual(
            AdaptiveEdgeConcurrencyPolicy.resolve(
                automaticModeEnabled: true,
                maxPerformanceRequested: false,
                connectivity: .wifi,
                isLowPowerModeEnabled: false,
                thermalState: .fair,
                recentEdgeFailures: 1
            ),
            .hybrid(maxConcurrentBackfillChunks: 2)
        )
        XCTAssertEqual(
            AdaptiveEdgeConcurrencyPolicy.resolve(
                automaticModeEnabled: true,
                maxPerformanceRequested: false,
                connectivity: .wifi,
                isLowPowerModeEnabled: false,
                thermalState: .fair,
                recentEdgeFailures: 2
            ),
            .hybrid(maxConcurrentBackfillChunks: 1)
        )
    }

    func testMaxPerformanceCanOptIntoSafeWifiHybridWhileExperimentalModeIsOff() {
        XCTAssertEqual(
            AdaptiveEdgeConcurrencyPolicy.resolve(
                automaticModeEnabled: false,
                maxPerformanceRequested: true,
                connectivity: .wifi,
                isLowPowerModeEnabled: false,
                thermalState: .nominal,
                recentEdgeFailures: 0
            ),
            .hybrid(maxConcurrentBackfillChunks: 3)
        )
    }
}
