// AsyncTimeoutTests.swift
//
// Verifies the `withTimeout(seconds:_:)` shim used across the iOS
// resilience surface (PythonBridge.parseEpub, EdgeTTSBridge per-frame).
// We test:
//   - Fast operations return their value without firing the timeout.
//   - Slow operations throw `TimeoutError` after the configured budget.
//   - The error carries the budget + label for diagnostics.
//   - Errors *from the work itself* are surfaced unchanged (i.e. the
//     timeout shim is transparent to non-timeout failures).
//   - Negative/zero budgets degrade to "no timeout" (programmer-error
//     guard) so tests / dev builds don't surprise-fail.

import XCTest
@testable import EpubToMp3

final class AsyncTimeoutTests: XCTestCase {

    func testFastOperationReturnsValueBeforeDeadline() async throws {
        let result: Int = try await withTimeout(seconds: 2) {
            // Returns essentially immediately — well under the 2 s budget.
            return 42
        }
        XCTAssertEqual(result, 42)
    }

    func testSlowOperationThrowsTimeoutError() async {
        do {
            _ = try await withTimeout(seconds: 0.1, label: "test") {
                // 1 s sleep; the 0.1 s budget must fire first.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "never"
            }
            XCTFail("expected TimeoutError")
        } catch let err as TimeoutError {
            XCTAssertEqual(err.seconds, 0.1, accuracy: 0.001)
            XCTAssertEqual(err.label, "test",
                "TimeoutError must carry the label for diagnostics")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testWorkErrorPropagatesUnchanged() async {
        struct MyError: Error, Equatable {}
        do {
            _ = try await withTimeout(seconds: 5) { () throws -> Int in
                throw MyError()
            }
            XCTFail("expected MyError")
        } catch let err as MyError {
            XCTAssertEqual(err, MyError())
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    /// Zero / negative budgets are treated as "no timeout" so a
    /// programmer typo doesn't accidentally fast-fail real work.
    func testZeroBudgetActsAsDisabled() async throws {
        let result = try await withTimeout(seconds: 0) {
            try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
            return "ok"
        }
        XCTAssertEqual(result, "ok")
    }

    func testNegativeBudgetActsAsDisabled() async throws {
        let result = try await withTimeout(seconds: -1) {
            return "ok"
        }
        XCTAssertEqual(result, "ok")
    }

    /// TimeoutError must be Equatable so call sites can `catch is
    /// TimeoutError` reliably — used in `BookOpenView` to distinguish
    /// "30 s parse timeout" from a real Python decode error.
    func testTimeoutErrorEquatability() {
        let a = TimeoutError(seconds: 5, label: "x")
        let b = TimeoutError(seconds: 5, label: "x")
        XCTAssertEqual(a, b)
    }

    func testTimeoutErrorDescriptionIncludesLabel() {
        let err = TimeoutError(seconds: 30, label: "EPUB parse")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("EPUB parse"),
            "errorDescription must mention the label so banners are informative")
        XCTAssertTrue(desc.contains("30"),
            "errorDescription must mention the deadline so users know the budget")
    }
}
