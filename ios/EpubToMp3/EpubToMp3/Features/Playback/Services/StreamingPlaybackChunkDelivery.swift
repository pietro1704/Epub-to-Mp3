import Foundation

/// Bridges Rust's synchronous chunk callback to the main-actor segment queue.
/// The callback waits for bounded file-backed acceptance before Rust continues.
final class StreamingPlaybackChunkDelivery: @unchecked Sendable {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var accepted = false

        func resolve(_ accepted: Bool) {
            lock.lock()
            self.accepted = accepted
            lock.unlock()
            semaphore.signal()
        }

        func wait() -> Bool {
            semaphore.wait()
            lock.lock()
            defer { lock.unlock() }
            return accepted
        }
    }

    /// File-backed segments Rust may run ahead of the player's own queue
    /// (`PlaybackQueueSession.maximumAhead`). Disk-only and bounded by
    /// `SegmentBacklog.maximumDeferredSegmentCount`; a deeper cushion lets
    /// playback outlast a screen-off synthesis slowdown, when an emptied queue
    /// would let iOS suspend the app.
    static let lookaheadSegments = 12

    private let player: AudioPlayer

    init(player: AudioPlayer) {
        self.player = player
    }

    func enqueue(
        _ data: Data,
        chapterIndex: Int,
        chunkIndex: Int,
        buffersAudio: Bool = true,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        onAccepted: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        let gate = Gate()
        Task { @MainActor [player] in
            guard isCurrent() else {
                gate.resolve(false)
                return
            }
            guard buffersAudio else {
                gate.resolve(true)
                return
            }
            let accepted = await player.enqueueSegmentAsync(
                data: data,
                chapterIndex: chapterIndex,
                segmentIndex: chunkIndex,
                maximumDeferredSegments: Self.lookaheadSegments
            )
            if accepted { onAccepted() }
            gate.resolve(accepted)
        }
        return gate.wait()
    }
}
