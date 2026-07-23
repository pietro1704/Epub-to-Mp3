import Foundation

/// Maps a chapter's audio playback position (in seconds) to the
/// corresponding sentence id in the source text.
///
/// Two timing modes:
///
/// 1. **Segment table** — when the backend emits `chapter.segments[]`
///    with `startMs`/`endMs`, we walk that table directly.
/// 2. **WPM estimation** — when no segment metadata is present, the
///    chapter is split on `.?!` boundaries and each sentence is given a
///    duration proportional to its character length, scaled by the
///    configured words-per-minute (default 200, matching `EXPECTED_WPM`
///    on the backend).
///
/// Per `.claude/agents/sync-engine.md`:
///   - Build the table once on chapter load — never mutate at runtime.
///   - Walk it on each playback tick (debounced 250ms upstream by
///     `AudioPlayer.position`).
///   - Re-emit only when the sentence actually changes.
///
/// `SyncEngine` is **pure logic** — no AVFoundation, no SwiftUI. It is
/// driven by the parent view binding `AudioPlayer.position` to
/// `update(position:)`. This keeps it testable on any platform.
final class SyncEngine: @unchecked Sendable {

    /// Sentence-level entry in the lookup table, with absolute ms
    /// boundaries relative to chapter start.
    struct TimingEntry: Equatable {
        let id: String
        let startMs: Int
        let endMs: Int
    }

    enum TimingSource: String, Equatable {
        /// Real per-segment timestamps from the backend.
        case segments
        /// Words-per-minute estimation (no segment metadata available).
        case wpmEstimate
        /// Empty chapter — no sentences to highlight.
        case empty
    }

    // MARK: Configuration

    /// Default WPM matches `EXPECTED_WPM=200` from the backend's Edge
    /// neural voices. Configurable per-instance for slower TTS engines
    /// (e.g. Piper around 160 WPM).
    let wpm: Int

    /// Average characters per word, used to translate sentence char
    /// length into word count. 5 is the standard English/PT-BR average.
    private let charsPerWord: Double = 5.0

    // MARK: State

    private(set) var spans: [SentenceSpan] = []
    private(set) var timing: [TimingEntry] = []
    private(set) var source: TimingSource = .empty
    private(set) var currentSentenceId: String?
    /// Maps backend timing identifiers to the stable ids rendered by ReaderView.
    /// Backend segment ids are not guaranteed to use SentenceSpan's id scheme.
    private var readerIDsByTimingID: [String: String] = [:]

    // MARK: Sentence change stream

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<String?>.Continuation] = [:]

    /// Stream that yields the active sentence id whenever it changes.
    /// Yields `nil` for "no active sentence" (chapter ended, position
    /// before first sentence, or empty chapter).
    var currentSentence: AsyncStream<String?> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.lock()
            self.continuations[id] = continuation
            self.lock.unlock()
            continuation.yield(self.currentSentenceId)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    private func broadcast(_ sentenceId: String?) {
        lock.lock()
        let conts = continuations.values
        lock.unlock()
        for c in conts { c.yield(sentenceId) }
    }

    // MARK: Init

    init(wpm: Int = 200) {
        self.wpm = max(60, wpm)
    }

    // MARK: Loading

    /// Load a chapter into the engine. Recomputes the timing table from
    /// segments when present, otherwise falls back to WPM estimation
    /// using `chapterDurationSeconds` as the total budget. If the
    /// duration is unknown (`<= 0`), the table is built without
    /// scaling — sentences are still ordered, just with proportional
    /// fake durations so the algorithm still walks linearly.
    func load(chapter: EbookFulltext.Chapter, chapterDurationSeconds: Double) {
        let computedSpans = chapter.splitSentences()
        spans = computedSpans

        guard !computedSpans.isEmpty else {
            timing = []
            readerIDsByTimingID = [:]
            source = .empty
            updateCurrent(nil)
            return
        }

        if let segments = chapter.segments, !segments.isEmpty,
           segments.allSatisfy({ $0.startMs != nil && $0.endMs != nil }) {
            let orderedSegments = segments.enumerated().map { idx, seg in (idx, seg) }
                .sorted { ($0.1.startMs ?? 0) < ($1.1.startMs ?? 0) }
            timing = orderedSegments.map { idx, seg in
                TimingEntry(
                    id: seg.id ?? "\(chapter.index):\(idx)",
                    startMs: seg.startMs ?? 0,
                    endMs: seg.endMs ?? (seg.startMs ?? 0)
                )
            }
            readerIDsByTimingID = orderedSegments.enumerated().reduce(into: [:]) { result, item in
                let position = item.offset
                let segment = item.element.1
                let timingID = timing[position].id
                let readerID = computedSpans.first(where: { span in
                    let segmentText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let spanText = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return !segmentText.isEmpty && (spanText == segmentText || spanText.contains(segmentText) || segmentText.contains(spanText))
                })?.id ?? (computedSpans.indices.contains(position) ? computedSpans[position].id : nil)
                if let readerID { result[timingID] = readerID }
            }
            source = .segments
        } else {
            readerIDsByTimingID = Dictionary(uniqueKeysWithValues: computedSpans.map { ($0.id, $0.id) })
            timing = estimateTiming(
                spans: computedSpans,
                durationSeconds: chapterDurationSeconds
            )
            source = .wpmEstimate
        }
        updateCurrent(nil)
    }

    /// Resolve a timing id into the id used by ReaderView's sentence spans.
    /// Returns the original id when no translation is necessary.
    func readerSentenceID(forTimingID timingID: String?) -> String? {
        guard let timingID else { return nil }
        return readerIDsByTimingID[timingID] ?? timingID
    }

    /// Pure helper used by `load(chapter:)` and tests. Distributes
    /// `durationSeconds` across `spans` proportional to character count.
    /// If `durationSeconds <= 0`, falls back to a WPM-derived duration
    /// per sentence (so tests can drive the engine without fake audio).
    func estimateTiming(spans: [SentenceSpan], durationSeconds: Double) -> [TimingEntry] {
        let totalChars = spans.reduce(0) { $0 + max(1, $1.text.count) }
        guard totalChars > 0 else { return [] }

        let totalMs: Double
        if durationSeconds > 0 {
            totalMs = durationSeconds * 1000.0
        } else {
            // Fallback: pure WPM. words = chars / charsPerWord;
            // duration_ms = words / wpm * 60_000.
            let words = Double(totalChars) / charsPerWord
            totalMs = words / Double(wpm) * 60_000.0
        }

        var entries: [TimingEntry] = []
        var cursor: Double = 0
        for span in spans {
            let share = Double(max(1, span.text.count)) / Double(totalChars)
            let dur = totalMs * share
            entries.append(TimingEntry(
                id: span.id,
                startMs: Int(cursor.rounded()),
                endMs: Int((cursor + dur).rounded())
            ))
            cursor += dur
        }
        return entries
    }

    // MARK: Position update

    /// Drive the engine with a new playback position. Called from the
    /// `AudioPlayer.position` stream on the UI side; the upstream is
    /// already debounced to ~250ms by the periodic time observer.
    @discardableResult
    func update(positionSeconds: Double) -> String? {
        guard !timing.isEmpty else {
            updateCurrent(nil)
            return nil
        }
        let positionMs = Int((positionSeconds * 1000.0).rounded())
        // Linear walk is fine — sentences are < 2K per chapter and the
        // tick rate is 4Hz. Binary search is overkill and would mask the
        // common forward-walk case where the next sentence is the next
        // index. Keep it linear and obvious.
        // Use `last` so that when two segments overlap (rare but possible with
        // backend-supplied timing), the most specific/recent one wins.
        let active = timing.last(where: { entry in
            positionMs >= entry.startMs && positionMs < entry.endMs
        }) ?? timing.last(where: { positionMs >= $0.startMs })

        let id = active?.id
        // If position is beyond the last entry's end, surface nil so the
        // UI can stop highlighting (chapter finished).
        if let last = timing.last, positionMs >= last.endMs {
            updateCurrent(nil)
            return nil
        }
        updateCurrent(id)
        return id
    }

    private func updateCurrent(_ id: String?) {
        guard id != currentSentenceId else { return }
        currentSentenceId = id
        broadcast(id)
    }
}
