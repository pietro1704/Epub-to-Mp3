import XCTest
@testable import EpubToMp3

final class ConversionResourcePolicyTests: XCTestCase {
    @MainActor
    func testInjectedPressureHoldsAllWaitersUntilAnExplicitStableBoundary() async {
        let policy = ConversionResourcePolicy()
        policy.setResourceConstraint(.thermalPressure)
        policy.refreshDeviceResourceConstraint()
        XCTAssertEqual(policy.constraint, .thermalPressure)
        var entered = 0
        var completed: [Int] = []
        let waiters = (0..<2).map { identity in
            Task { @MainActor in
                entered += 1
                await policy.waitForChange()
                completed.append(identity)
            }
        }
        for _ in 0..<100 where entered < 2 { await Task.yield() }
        XCTAssertEqual(entered, 2)
        XCTAssertTrue(completed.isEmpty)
        policy.setResourceConstraint(.stable)
        for waiter in waiters { await waiter.value }
        XCTAssertEqual(completed.sorted(), [0, 1])
        policy.setResourceConstraint(.stable)
        XCTAssertEqual(completed.count, 2)
    }

    @MainActor
    func testPressureAlreadyClearedBeforeRegistrationDoesNotLoseTheWakeup() async {
        let policy = ConversionResourcePolicy()
        policy.setResourceConstraint(.lowPower)
        policy.setResourceConstraint(.stable)
        await policy.waitForChange()
        XCTAssertEqual(policy.constraint, .stable)
    }
}
