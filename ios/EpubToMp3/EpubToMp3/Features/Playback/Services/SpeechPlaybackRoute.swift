import Foundation

/// MP3 remains primary; this value only selects a route and never starts audio.
enum SpeechPlaybackRoute {
    /// Outcome of `playOrFallback`. Returned synchronously so UI surfaces
    /// can decide whether to update a "now playing" banner, surface a
    /// "still converting" hint, or stay silent. `Equatable` so tests can
    /// pin the result; the discriminant is enough — no associated data
    /// needed today.
    enum AttemptResult: Equatable {
        case startedAudio
        case startedSpeechFallback
        case noOp
    }

    case audio(JobSnapshot, playableOffset: Int)
    case speech(String)
    case unavailable

    /// True when the host should drive the speech-fallback path instead
    /// of the MP3 path for the given chapter. The MP3 path is preferred
    /// — fallback only fires when no snapshot exists, the snapshot
    /// carries no playable chapters, or the chapter at the requested
    /// index has no `downloadUrl` yet.
    ///
    /// Pure decision helper — does not mutate state. Callers combine
    /// this with chapter-text availability (only the reader/view layer
    /// knows about `EbookFulltext`) before invoking `playFallbackSpeech`.
    nonisolated static func shouldUseSpeechFallback(for snapshot: JobSnapshot?, chapterIndex: Int) -> Bool {
        guard let snapshot else { return true }
        let playable = snapshot.playableChapters
        if playable.isEmpty { return true }
        // Requested index lives in the EPUB-zero-based space (same key
        // `chapter.index` uses in the snapshot). If the snapshot lacks
        // an entry for it, MP3 is not ready for THIS chapter even if
        // earlier/later ones are.
        return !playable.contains { $0.index == chapterIndex }
    }

    /// Unified play entry the reader/UI surfaces call when the user taps
    /// Play. Resolves the route once so callers don't have to duplicate
    /// the "is MP3 ready? else can we speak? else do nothing" tree at
    /// every button site.
    ///
    /// Decision order — MP3 is ALWAYS primary:
    /// 1. The requested EPUB chapter has a playable `downloadUrl` in the
    ///    snapshot ⇒ `.startedAudio` (existing `play(snapshot:startingAt:)`
    ///    path, including the MP3-takeover stop of any active fallback).
    /// 2. The snapshot lacks a playable URL for the requested chapter
    ///    AND `chapterText` has non-whitespace content ⇒
    ///    `.startedSpeechFallback` (accessibility synth).
    /// 3. Neither ⇒ `.noOp` — no transport state mutates, no flag flips,
    ///    no UI flicker.
    ///
    /// `chapterIndex` is the EPUB-zero-based index (same space the reader
    /// publishes into UserDefaults). Translation to
    /// the playable-list index used by `play(snapshot:startingAt:)` is
    /// done here so call sites never need both numbers.
    nonisolated static func plan(snapshot: JobSnapshot?, chapterIndex: Int, chapterText: String?) -> Self {
        if let snapshot, let offset = snapshot.playableChapters.firstIndex(where: { $0.index == chapterIndex }) {
            return .audio(snapshot, playableOffset: offset)
        }
        let text = (chapterText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .unavailable : .speech(text)
    }
}
