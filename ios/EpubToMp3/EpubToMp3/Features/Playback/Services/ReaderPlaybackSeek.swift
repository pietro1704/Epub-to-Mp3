import Foundation

/// Owns bounded sentence timing and resolves a reader anchor into one playback
/// command. Snapshot loading must finish before a proportional seek is applied.
@MainActor
final class ReaderPlaybackSeek {
    enum Anchor { case sentence(TimeInterval), ratio(Double), beginning }
    enum Plan {
        case resume
        case pending(PendingPlaybackSeek.ChapterRequest, waitingForFirstAudio: Bool)
        case chapter(Int, Anchor)
    }
    /// Per-chapter sentence-id → audio-ms timing maps. Populated by the
    /// `SentenceSyncEngine` host when the native reader loads a
    /// chapter. Lookup is cheap and only used by `startFromReaderPage`
    /// when a precise sentence-anchored seek is preferred over the
    /// char-uniform ratio approximation. Capped at the most-recent ~8
    /// chapters to keep memory bounded.

    private var sentenceTimingByChapter: [Int: [String: Int]] = [:]
    private var sentenceTimingOrder: [Int] = []
    private static let sentenceTimingCacheSize = 8
    func timingMap(for chapter: Int) -> [String: Int]? { sentenceTimingByChapter[chapter] }
    /// Inject a sentence-id → start-ms map for `chapterIndex` (which
    /// is a playable-chapter index, same space as `currentChapterIndex`).
    /// Idempotent; pass an empty dictionary to clear.
    func setTiming(_ map: [String: Int], forChapterIndex chapterIndex: Int) {
        if map.isEmpty {
            sentenceTimingByChapter.removeValue(forKey: chapterIndex)
            sentenceTimingOrder.removeAll { $0 == chapterIndex }
            return
        }
        sentenceTimingByChapter[chapterIndex] = map
        sentenceTimingOrder.removeAll { $0 == chapterIndex }
        sentenceTimingOrder.append(chapterIndex)
        while sentenceTimingOrder.count > Self.sentenceTimingCacheSize {
            let evict = sentenceTimingOrder.removeFirst()
            sentenceTimingByChapter.removeValue(forKey: evict)
        }
    }
    func plan(chapter readerChapterIndex: Int, sentenceID: String?, ratio: Double?, wordRatio: Double?,
              snapshot: JobSnapshot?, hasPlayer: Bool, segmentMode: Bool,
              segments: PlaybackSegmentSession, navigation: ChapterNavigationDecision) -> Plan {
        guard let snapshot else { return .resume }
        if !hasPlayer, snapshot.playableChapters.isEmpty, !snapshot.isTerminal {
            let ratio = ratio.flatMap { $0.isFinite ? max(0, min(1, $0)) : nil }
            return .pending(.init(id: UUID(), jobID: snapshot.jobId, chapterIndex: readerChapterIndex,
                                  autoplay: true, readerPageRatio: ratio), waitingForFirstAudio: true)
        }
        if segmentMode, hasPlayer {
            let duration = segments.confirmedEnd(for: readerChapterIndex, snapshot: snapshot)
                ?? segments.estimatedDurations[readerChapterIndex] ?? 0
            let ratio = max(0, min(1, ratio ?? 0))
            let position = sentencePosition(sentenceID, chapter: readerChapterIndex, wordRatio: wordRatio)
            return .pending(.init(id: UUID(), jobID: snapshot.jobId, chapterIndex: readerChapterIndex,
                                  autoplay: true, position: position ?? ratio * duration,
                                  readerPageRatio: position == nil && ratio > 0 && duration <= 0 ? ratio : nil),
                            waitingForFirstAudio: false)
        }
        // Reader space is EPUB-zero-based. A nonnarratable preface selects the
        // first playable chapter rather than silently producing no audio.
        let target = navigation.playableIndex(forEpubZeroBased: readerChapterIndex, in: snapshot) ?? 0
        if let position = sentencePosition(sentenceID, chapter: target, wordRatio: wordRatio) {
            return .chapter(target, .sentence(position))
        }
        if let ratio, ratio > 0 { return .chapter(target, .ratio(ratio)) }
        return .chapter(target, .beginning)
    }

    private func sentencePosition(_ sentenceID: String?, chapter: Int, wordRatio: Double?) -> TimeInterval? {
        guard let sentenceID, let map = sentenceTimingByChapter[chapter], let start = map[sentenceID] else { return nil }
        return Self.sentenceStartMs(startMs: start, nextStartMs: map.values.filter { $0 > start }.min(),
                                    offsetRatio: wordRatio ?? 0) / 1000
    }
    nonisolated static func sentenceStartMs(
        startMs: Int,
        nextStartMs: Int?,
        offsetRatio: Double
    ) -> Double {
        let ratio = min(1, max(0, offsetRatio.isFinite ? offsetRatio : 0))
        let endMs = max(startMs, nextStartMs ?? startMs)
        return Double(startMs) + Double(endMs - startMs) * ratio
    }
}
