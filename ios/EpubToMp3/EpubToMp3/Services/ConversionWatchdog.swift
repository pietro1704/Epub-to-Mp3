// ConversionWatchdog.swift
//
// Heart-beat based stall detector for long-running conversions
// (`BookOpenView.bootstrapEmbedded` + SSE subscription path).
//
// Why a watchdog (not just timeouts):
//   - The audio bootstrap is *expected* to take minutes — a single
//     timeout would either be too short (false positives mid-book) or
//     too long (real stalls wait 5 min to surface). The progress signal
//     we actually care about is "did *anything* happen recently?":
//       * SSE event arrived
//       * Segment enqueued in `AudioPlayer.enqueueSegment`
//       * Chapter completed (`chaptersCompleted` incremented)
//   - If nothing happens for `stallThreshold` seconds, treat the
//     pipeline as wedged. Cancel + retry once automatically. After
//     `maxAutoRetries` consecutive stalls, surface the error to the UI
//     so the user can decide.
//
// Lifecycle:
//   let wd = ConversionWatchdog(stallSeconds: 90)
//   wd.onStall = { Task { await retry() } }
//   wd.onGaveUp = { phase = .error("Audio stalled. Try again.") }
//   wd.start()
//   …
//   wd.heartbeat()   // call on every visible progress event
//   wd.stop()        // when the job reaches a terminal state
//
// Concurrency: all mutation is funnelled through `@MainActor` so SwiftUI
// state writes from `onStall` / `onGaveUp` are safe by construction.

import Foundation

@MainActor
final class ConversionWatchdog {
    /// Wall-clock seconds of silence that count as a stall. Default 90 s
    /// matches the slice spec — long enough that a slow Edge chapter
    /// (30-60 s synth) doesn't trip the wire, short enough that a real
    /// hang is caught before the user gives up.
    let stallSeconds: TimeInterval

    /// Polling interval. 5 s is a sane trade-off between responsiveness
    /// and battery cost; the watchdog never wakes more than ~12×/min.
    let pollSeconds: TimeInterval

    /// Maximum number of *automatic* retry attempts before bubbling the
    /// failure up to the UI via ``onGaveUp``. 2 keeps the auto-recovery
    /// useful for transient network blips without masking real failures.
    let maxAutoRetries: Int

    /// Called when a stall is detected AND we still have retry budget.
    /// Implementer is responsible for cancelling the current pipeline
    /// and scheduling a retry; the watchdog only signals.
    var onStall: (@MainActor () -> Void)?

    /// Called when we've exhausted ``maxAutoRetries`` consecutive stalls.
    /// At this point the user must see an error UI with a manual retry
    /// button.
    var onGaveUp: (@MainActor () -> Void)?

    /// `true` while the polling timer is live. Exposed for tests.
    private(set) var isRunning: Bool = false

    /// Counts retries triggered without an intervening heartbeat. A
    /// successful retry that beats the next stall threshold resets this
    /// to zero (via ``heartbeat``).
    private(set) var consecutiveStalls: Int = 0

    private var lastBeat: Date = .distantPast
    private var pollTask: Task<Void, Never>?
    /// Injectable clock for deterministic tests (defaults to `Date()`).
    private let now: @Sendable () -> Date

    init(
        stallSeconds: TimeInterval = 90,
        pollSeconds: TimeInterval = 5,
        maxAutoRetries: Int = 2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stallSeconds = stallSeconds
        self.pollSeconds = pollSeconds
        self.maxAutoRetries = maxAutoRetries
        self.now = now
    }

    /// Begin polling. Safe to call again — it's a no-op when already
    /// running. Also records an immediate heartbeat so a freshly-started
    /// watchdog does not fire on the very first tick.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        consecutiveStalls = 0
        lastBeat = now()
        pollTask = Task { [weak self] in
            guard let self else { return }
            let interval = await MainActor.run { self.pollSeconds }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.tick()
            }
        }
    }

    /// Stop polling and reset state. Call when the job reaches a
    /// terminal state or when the user leaves the screen.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
        consecutiveStalls = 0
        lastBeat = .distantPast
    }

    /// Record a sign of life. Resets the silence timer AND the
    /// consecutive-stalls counter (because we just made progress, so
    /// any prior auto-retry succeeded).
    func heartbeat() {
        lastBeat = now()
        consecutiveStalls = 0
    }

    /// Internal: examine elapsed silence and fire callbacks accordingly.
    /// Exposed `internal` so tests can drive the watchdog deterministically
    /// without a real `Task.sleep`.
    func tick() {
        guard isRunning else { return }
        let silentFor = now().timeIntervalSince(lastBeat)
        guard silentFor >= stallSeconds else { return }

        // Reset the silence clock immediately. Otherwise we'd fire the
        // callback on every poll until the retry produces a heartbeat,
        // which would spam `onStall` multiple times for a single stall.
        lastBeat = now()
        consecutiveStalls += 1

        if consecutiveStalls > maxAutoRetries {
            onGaveUp?()
            // Stop so we don't keep firing onGaveUp on every poll.
            stop()
        } else {
            onStall?()
        }
    }
}
