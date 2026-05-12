// AsyncTimeout.swift
//
// Tiny shim that wraps any `async throws` operation in a wall-clock
// deadline. Exists because:
//
//  - iOS 17's `Task.timeout` is iOS 17-only; our deployment target is
//    iOS 15 (see ce8e547 — migrated `@Observable` → `ObservableObject`
//    for iOS 15 readiness).
//  - Several critical paths (`PythonBridge.parseEpub`,
//    `convertChapterStreaming`, `EdgeTTSBridge.synthesize`, the SSE
//    stream subscription) can stall silently and leave the UI spinning
//    forever. Wrapping them in `withTimeout` guarantees the call site
//    sees either a result or a `TimeoutError` within a known bound.
//
// Usage:
//   let bytes = try await withTimeout(seconds: 15) {
//       try await edge.synthesize(ssml: …)
//   }
//
// Cancellation semantics: when the timeout fires we cancel the work
// task. The work task MUST respect cancellation (`Task.isCancelled`
// checks or cancellable AsyncSequence/URLSession calls) for the
// underlying resource to actually release; otherwise the timeout only
// frees the *caller*. Most of our async I/O already does this — Foundation
// `URLSession` cancels on task cancellation, and `Task.sleep` throws.

import Foundation

/// Thrown by ``withTimeout(seconds:_:)`` when the deadline elapses
/// before the wrapped work completes.
struct TimeoutError: Error, LocalizedError, Equatable {
    /// Wall-clock budget that elapsed. Surface in UI for diagnostics.
    let seconds: TimeInterval
    /// Optional human label so different call sites distinguish in
    /// banners ("EPUB parse timed out" vs "Audio synth timed out").
    let label: String?

    init(seconds: TimeInterval, label: String? = nil) {
        self.seconds = seconds
        self.label = label
    }

    var errorDescription: String? {
        let base = label.map { "\($0) timed out" } ?? "Operation timed out"
        return "\(base) after \(Int(seconds))s"
    }
}

/// Run `work` with a wall-clock deadline. If `seconds` elapses before
/// `work` returns, the work task is cancelled and ``TimeoutError`` is
/// thrown to the caller.
///
/// - Parameters:
///   - seconds: deadline budget in seconds. Must be > 0; pass a
///     very small value (e.g. 0.05) only in tests.
///   - label: optional debug label surfaced in ``TimeoutError`` for
///     better diagnostics in banners / logs.
///   - work: the async operation to bound.
/// - Returns: whatever `work` returns when it wins the race.
/// - Throws: ``TimeoutError`` on timeout; anything `work` throws on
///   its own error path; ``CancellationError`` if the *enclosing* task
///   is cancelled.
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    label: String? = nil,
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    // Special-case: zero / negative budgets are programmer error. Treat
    // as "no timeout" to avoid spurious failures in dev builds.
    guard seconds > 0 else {
        return try await work()
    }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            // `Task.sleep` is cancellation-aware: when the group is
            // cancelled (because `work` won the race) the sleep throws,
            // releasing the timer without invoking the timeout branch.
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds, label: label)
        }

        // First task to finish wins; cancel the loser so its resources
        // (URLSession task, dispatch work item) get released promptly.
        defer { group.cancelAll() }
        // Force-unwrap is safe: the group has exactly two tasks; at
        // least one will resolve before `next()` returns nil.
        let first = try await group.next()!
        return first
    }
}
