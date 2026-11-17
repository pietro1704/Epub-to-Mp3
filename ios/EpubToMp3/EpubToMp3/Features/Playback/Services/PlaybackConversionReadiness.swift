import Combine
import Foundation

/// Owns conversion progress and one-way audio-readiness latches for a book.
/// The coordinator decides when a new session may clear them; this owner never
/// creates a queue, starts synthesis, or grants autoplay.
@MainActor
final class PlaybackConversionReadiness: ObservableObject {
    /// `true` while a TTS conversion job is actively running for the
    /// currently-open book. Set by the native reader
    /// when they submit or reattach to a conversion job and cleared
    /// when the job reaches a terminal state. Does NOT imply the
    /// player has a loaded audio item — use `firstChapterReady` for that.
    @Published var isConverting: Bool = false
    /// 0.0–1.0 fraction of chapters whose audio is ready, or `nil`
    /// when total chapter count is unknown. Drives the conversion
    /// progress indicator in the native player and reader.
    @Published var conversionProgress: Double? = nil
    /// Becomes `true` as soon as the first chapter MP3 is available
    /// (i.e. `snapshot.playableChapters` becomes non-empty for the
    /// first time). Once `true` it never goes back to `false` for the
    /// same book session so the transport controls are never hidden
    /// after they have appeared.
    @Published private(set) var firstChapterReady: Bool = false
    /// Becomes `true` as soon as the *first audio segment* of the
    /// current chapter has been enqueued via `enqueueSegment(data:…)`.
    /// This fires earlier than `firstChapterReady` (which waits for the
    /// whole chapter MP3) — typically within 500 ms of synthesis start —
    /// satisfying the HIG < 3 s time-to-first-byte requirement.
    /// One-way latch: once `true` it stays `true` for the session.
    @Published private(set) var firstSegmentReady: Bool = false

    func markFirstChapterReady() {
        firstChapterReady = true
    }

    /// Marks a user-initiated Listen request as loading before runtime
    /// warmup and EPUB parsing finish. The mini and expanded players derive
    /// their spinner state from this flag until the first audio arrives.
    func beginPlaybackPreparation() {
        isConverting = true
    }

    /// Reset conversion-tracking state when a new book session starts
    /// so stale progress from a previous book is never shown.
    func reset(clearLatches: Bool) {
        isConverting = false
        conversionProgress = nil
        if clearLatches {
            firstChapterReady = false
            firstSegmentReady = false
        }
    }
    func markFirstSegmentReady() {
        if !firstSegmentReady {
            firstSegmentReady = true
            // Also raise firstChapterReady so the mini-player shows play/pause.
            firstChapterReady = true
        }
    }
}
