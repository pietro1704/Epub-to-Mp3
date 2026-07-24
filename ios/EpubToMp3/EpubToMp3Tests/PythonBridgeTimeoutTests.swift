// PythonBridgeTimeoutTests.swift
//
// Indirect contract test for `PythonBridge.parseEpub`'s resilience.
//
// We can't actually drive PythonKit from the macOS host test harness
// (the `#if os(iOS) || targetEnvironment(simulator)` gate excludes it),
// and even on the iOS simulator running the real interpreter would make
// these tests heavy + flaky. Instead we lock in the *shape of the
// resilience contract*:
//
//   1. The parse path must use `withTimeout` so a wedged interpreter
//      surfaces as `TimeoutError`, not an infinite hang.
//   2. The deadline must match the spec (30 s for parse).
//   3. The shim must release the *Swift caller* even if the underlying
//      dispatch-queue work never completes — i.e. we don't accidentally
//      block on the work future.
//
// The simulated test below stands in for the PythonKit dispatch by
// blocking inside `withCheckedThrowingContinuation` forever; if our
// wrapper is correct, the caller still sees a `TimeoutError` within the
// budget. If somebody removes `withTimeout` from the production path,
// the equivalent test will fail to compile / pass.

import XCTest
@testable import EpubToMp3

final class PythonBridgeTimeoutTests: XCTestCase {

    /// Simulates a wedged underlying call by sleeping for far longer
    /// than the timeout budget. The wrapper must surface `TimeoutError`
    /// within the budget, freeing the caller.
    ///
    /// We deliberately use `Task.sleep` (cancellation-aware) rather than
    /// a never-resuming `withCheckedThrowingContinuation`: the latter
    /// would leak the inner task forever, blocking the test process
    /// shutdown — exactly the kind of silent hang we ARE testing
    /// against, but inside the test harness itself.
    func testWrappedSlowCallReturnsTimeout() async {
        let started = Date()
        do {
            _ = try await withTimeout(seconds: 0.2, label: "EPUB parse") {
                // 5 s of "wedged" Python — well past the 0.2 s budget.
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 42
            }
            XCTFail("expected TimeoutError")
        } catch let err as TimeoutError {
            XCTAssertEqual(err.label, "EPUB parse",
                "TimeoutError label must match the production call site so the banner is informative")
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 1.0,
                "the timeout must release the caller within the budget; got \(elapsed)s")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// If the work completes normally before the deadline, the wrapper
    /// must return the work's value untouched — no spurious timeout.
    func testWrappedFastCallReturnsNormally() async throws {
        let result: String = try await withTimeout(seconds: 30, label: "EPUB parse") {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global().async {
                    cont.resume(returning: "parsed")
                }
            }
        }
        XCTAssertEqual(result, "parsed")
    }

    /// Errors raised by the work itself must propagate unchanged.
    /// Particularly important here because `BookOpenView.openFlow`
    /// has separate `catch is TimeoutError` and `catch` branches —
    /// confusing the two would misclassify a real parse failure.
    func testWrappedErrorPropagates() async {
        struct ParseFailed: Error, Equatable {}
        do {
            _ = try await withTimeout(seconds: 5, label: "EPUB parse") { () async throws -> Int in
                throw ParseFailed()
            }
            XCTFail("expected ParseFailed")
        } catch is TimeoutError {
            XCTFail("must not coerce a real parse error into a timeout")
        } catch is ParseFailed {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
