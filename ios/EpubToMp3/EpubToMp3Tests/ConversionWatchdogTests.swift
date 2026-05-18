// ConversionWatchdogTests.swift
//
// Drives `ConversionWatchdog` deterministically via the injectable
// clock. We never rely on real `Task.sleep` so the suite runs in
// milliseconds and can't flake on a busy CI runner.
//
// Coverage:
//   - heartbeat resets the silence timer (no callback fires).
//   - silence beyond `stallSeconds` fires `onStall`.
//   - consecutive silent stalls escalate to `onGaveUp` after
//     `maxAutoRetries` retries.
//   - a heartbeat after a stall resets `consecutiveStalls` to zero
//     (matches the "successful retry resumes" semantic).
//   - `stop()` is idempotent and cleans state.
//   - `start()` is a no-op when already running (no duplicate timers).

import XCTest
@testable import EpubToMp3

@MainActor
final class ConversionWatchdogTests: XCTestCase {

    /// Mutable clock the watchdog will read on every `tick` / heartbeat.
    /// We poke this around to simulate elapsed wall-clock time.
    private final class Clock: @unchecked Sendable {
        var now: Date
        init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { self.now = start }
        func read() -> Date { now }
        func advance(by seconds: TimeInterval) { now.addTimeInterval(seconds) }
    }

    // MARK: - Heartbeat semantics

    func testHeartbeatPreventsStallCallback() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 2,
            now: { clock.read() }
        )
        var stallCount = 0
        wd.onStall = { stallCount += 1 }
        wd.start()

        // Advance 4 s — under the 5 s threshold; tick should be a no-op.
        clock.advance(by: 4)
        wd.tick()
        XCTAssertEqual(stallCount, 0,
            "tick under stallSeconds must not fire onStall")
        wd.stop()
    }

    func testSilenceBeyondThresholdFiresStall() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 2,
            now: { clock.read() }
        )
        var stallCount = 0
        wd.onStall = { stallCount += 1 }
        wd.start()

        clock.advance(by: 10)
        wd.tick()
        XCTAssertEqual(stallCount, 1,
            "silence > stallSeconds must fire onStall exactly once")
        wd.stop()
    }

    func testHeartbeatResetsSilenceClock() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 2,
            now: { clock.read() }
        )
        var stallCount = 0
        wd.onStall = { stallCount += 1 }
        wd.start()

        clock.advance(by: 4)
        wd.heartbeat()  // resets timer back to "now"
        clock.advance(by: 4)
        wd.tick()
        XCTAssertEqual(stallCount, 0,
            "heartbeat must reset the silence clock so a near-miss doesn't fire")
        wd.stop()
    }

    // MARK: - Escalation

    func testEscalatesToGaveUpAfterMaxRetries() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 2,
            now: { clock.read() }
        )
        var stallCount = 0
        var gaveUpCount = 0
        wd.onStall = { stallCount += 1 }
        wd.onGaveUp = { gaveUpCount += 1 }
        wd.start()

        // Three stalls in a row: 1st and 2nd → onStall; 3rd → onGaveUp.
        for _ in 0..<3 {
            clock.advance(by: 10)
            wd.tick()
        }
        XCTAssertEqual(stallCount, 2,
            "with maxAutoRetries=2 we expect 2 onStall fires before giving up")
        XCTAssertEqual(gaveUpCount, 1,
            "the 3rd consecutive stall must fire onGaveUp exactly once")
        XCTAssertFalse(wd.isRunning,
            "watchdog must stop itself after onGaveUp so it doesn't spam")
    }

    func testGaveUpStopsAutoSoNoFurtherFires() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 1,
            now: { clock.read() }
        )
        var gaveUpCount = 0
        wd.onGaveUp = { gaveUpCount += 1 }
        wd.start()

        clock.advance(by: 10); wd.tick()  // stall #1 → onStall
        clock.advance(by: 10); wd.tick()  // stall #2 → onGaveUp, stops
        clock.advance(by: 10); wd.tick()  // already stopped; no-op
        XCTAssertEqual(gaveUpCount, 1)
    }

    func testHeartbeatAfterStallResetsRetryCounter() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 2,
            now: { clock.read() }
        )
        var stallCount = 0
        var gaveUpCount = 0
        wd.onStall = { stallCount += 1 }
        wd.onGaveUp = { gaveUpCount += 1 }
        wd.start()

        clock.advance(by: 10); wd.tick()        // 1st stall
        wd.heartbeat()                          // "retry succeeded"
        clock.advance(by: 10); wd.tick()        // back to a fresh 1st stall

        XCTAssertEqual(stallCount, 2,
            "two stalls fired because heartbeat reset the consecutive counter")
        XCTAssertEqual(gaveUpCount, 0,
            "onGaveUp must NOT fire after a heartbeat-mediated reset")
        XCTAssertEqual(wd.consecutiveStalls, 1,
            "consecutiveStalls should be back to 1 after the new stall")
        wd.stop()
    }

    // MARK: - Lifecycle

    func testStopIsIdempotent() {
        let wd = ConversionWatchdog()
        wd.start()
        wd.stop()
        wd.stop()  // must not crash
        XCTAssertFalse(wd.isRunning)
        XCTAssertEqual(wd.consecutiveStalls, 0)
    }

    func testStartIsNoopWhenAlreadyRunning() {
        let wd = ConversionWatchdog(stallSeconds: 5, pollSeconds: 60)
        wd.start()
        XCTAssertTrue(wd.isRunning)
        wd.start()  // second start must not throw / duplicate state
        XCTAssertTrue(wd.isRunning)
        wd.stop()
    }

    func testTickIsNoopWhenNotRunning() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 1, pollSeconds: 1, maxAutoRetries: 1,
            now: { clock.read() }
        )
        var stallCount = 0
        wd.onStall = { stallCount += 1 }
        clock.advance(by: 100)
        wd.tick()  // never started
        XCTAssertEqual(stallCount, 0,
            "tick must be a no-op when the watchdog is stopped")
    }

    // MARK: - Live Activity wiring contract
    //
    // WidgetDataSync.startConversionActivity / endConversionActivity are
    // called from BookOpenView (a SwiftUI view), not from ConversionWatchdog
    // itself. Direct unit-testing of those call sites requires a UITest or
    // a refactor that introduces a WidgetDataSync protocol — neither is in
    // scope here. The tests below instead verify the state-machine invariants
    // that the call sites rely on, so any regression in the watchdog
    // lifecycle contract is caught before it can silently break the wiring.

    /// The watchdog stops itself after onGaveUp, which is exactly the
    /// "conversion failed" signal the BookOpenView uses to call
    /// endConversionActivity(failed: true). Verify the stopped state is
    /// stable so the view can safely call end once.
    func testIsRunningFalseAfterGaveUp() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 1,
            now: { clock.read() }
        )
        wd.start()
        clock.advance(by: 10); wd.tick()  // onStall
        clock.advance(by: 10); wd.tick()  // onGaveUp → auto-stop
        XCTAssertFalse(wd.isRunning,
            "watchdog must be stopped when onGaveUp fires so BookOpenView can end the Live Activity exactly once")
    }

    /// After stop(), consecutiveStalls is zero — the view should not carry
    /// over a stale "failed" signal into the next startConversionActivity.
    func testStopClearsRetryCounter() {
        let clock = Clock()
        let wd = ConversionWatchdog(
            stallSeconds: 5, pollSeconds: 1, maxAutoRetries: 3,
            now: { clock.read() }
        )
        wd.start()
        clock.advance(by: 10); wd.tick()  // stall #1
        clock.advance(by: 10); wd.tick()  // stall #2
        wd.stop()
        XCTAssertEqual(wd.consecutiveStalls, 0,
            "stop() must reset consecutiveStalls so a fresh activity start is clean")
        XCTAssertFalse(wd.isRunning)
    }
}
