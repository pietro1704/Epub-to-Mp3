import AVFoundation
import Foundation

/// Owns wall-clock expiry, fade cancellation and volume restoration. Transport
/// position remains in PlaybackClock; a fade retains its pause callback only
/// until completion, matching the lifetime of the original playback task.
@MainActor
final class SleepPlaybackTimer {
    private let clock: PlaybackClock
    private let now: () -> Date
    private let sleep: (UInt64) async throws -> Void
    private var expiresAt: Date?
    private var cancelled = false
    private var fadeTask: Task<Void, Never>?

    init(
        clock: PlaybackClock,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.clock = clock
        self.now = now
        self.sleep = sleep
    }

    /// Positive values arm the timer. Zero or negative values cancel its
    /// expiry and any current fade without changing playback position.
    /// Set or cancel the sleep timer. Pass 0 to cancel; any positive
    /// value schedules an auto-pause that many seconds from now.
    func set(seconds: TimeInterval) {
        if seconds <= 0 {
            cancelled = true
            fadeTask?.cancel()
            fadeTask = nil
            clock.update(sleepTimerRemaining: 0)
            expiresAt = nil
            return
        }
        cancelled = false
        clock.update(sleepTimerRemaining: seconds)
        expiresAt = now().addingTimeInterval(seconds)
    }

    /// Called by the existing player time observer. Returning the current
    /// task also allows callers to await completion without a wall-clock wait.
    @discardableResult
    func tick(player: AVQueuePlayer?, pause: @escaping @MainActor () -> Void) -> Task<Void, Never>? {
        guard let expiry = expiresAt else { return fadeTask }
        let remaining = expiry.timeIntervalSince(now())
        if remaining > 0 {
            clock.update(sleepTimerRemaining: remaining)
            return fadeTask
        }
        clock.update(sleepTimerRemaining: 0)
        expiresAt = nil
        guard fadeTask == nil else { return fadeTask }
        cancelled = false
        fadeTask = Task { @MainActor in
            await fade(player: player, pause: pause)
            self.fadeTask = nil
        }
        return fadeTask
    }

    /// Twenty half-second intervals plus the final zero-volume step preserve
    /// the existing fade schedule. Restore volume on every exit, including a
    /// failed sleep and cancellation, so the next playback is unaffected.
    private func fade(player: AVQueuePlayer?, pause: @MainActor () -> Void) async {
        guard let player else {
            pause()
            return
        }
        let originalVolume = player.volume
        defer { player.volume = originalVolume }
        for step in stride(from: 20, through: 0, by: -1) {
            guard !cancelled, !Task.isCancelled else { return }
            player.volume = originalVolume * (Float(step) / 20)
            do {
                try await sleep(500_000_000)
            } catch {
                return
            }
        }
        guard !cancelled else { return }
        pause()
    }
    /// Schedule a whole-minute timer; zero cancels.
    func start(minutes: Int) { set(seconds: TimeInterval(minutes) * 60) }
    /// Cancel the active timer.
    func cancel() { set(seconds: 0) }
}
