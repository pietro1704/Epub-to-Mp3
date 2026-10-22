import Foundation

/// Synchronously registers each subscriber and terminates all streams when the
/// owner dies. Transport and chapter streams keep independent subscriber IDs.
@MainActor
final class PlaybackBroadcast {
    // Deinit is nonisolated under Swift 6. These continuations are otherwise
    // mutated only on MainActor; termination callbacks explicitly hop back.
    // `nonisolated(unsafe)` so `deinit` (non-isolated under Swift 6
    // on a `@MainActor` class) can drain them. The dictionaries are
    // only mutated from the @MainActor body of `currentChapter` /
    // `position` and from the `onTermination` continuation
    // (already-dispatched to MainActor). At deinit time all weak-self
    // tasks have returned early so no concurrent mutator races.
    nonisolated(unsafe) private var chapterContinuations: [UUID: AsyncStream<JobSnapshot.Chapter?>.Continuation] = [:]
    nonisolated(unsafe) private var positionContinuations: [UUID: AsyncStream<TimeInterval>.Continuation] = [:]
    deinit {
        // Finish unbroken for-await subscribers instead of retaining their tasks
        // forever after the player that produced this stream has been released.
        for continuation in chapterContinuations.values { continuation.finish() }
        for continuation in positionContinuations.values { continuation.finish() }
    }
    func publishChapter(_ value: JobSnapshot.Chapter?) {
        for continuation in chapterContinuations.values { continuation.yield(value) }
    }
    func publishPosition(_ value: TimeInterval) {
        for continuation in positionContinuations.values { continuation.yield(value) }
    }
    func chapters(initial: JobSnapshot.Chapter?) -> AsyncStream<JobSnapshot.Chapter?> {
        AsyncStream { continuation in
            let id = UUID()
            // This property is MainActor-isolated. Register synchronously so
            // the initial value is available before an async consumer starts
            // waiting; an extra actor hop can deadlock async-let consumers.
            chapterContinuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.chapterContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Position stream — debounced to ~250ms by sampling on a periodic
    /// time observer (`AVPlayer.addPeriodicTimeObserver` interval = 0.25s).
    func positions(initial: TimeInterval) -> AsyncStream<TimeInterval> {
        AsyncStream { continuation in
            let id = UUID()
            // Register synchronously for deterministic initial delivery and
            // to avoid an actor-hop deadlock with concurrent consumers.
            positionContinuations[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.positionContinuations.removeValue(forKey: id)
                }
            }
        }
    }

}
