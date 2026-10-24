import Foundation

/// Reconciles immutable chapter identities across append-only live queues,
/// replacement URLs, and persisted EPUB indexes. It never advances transport.
enum PlaybackChapterQueue {

    /// Pure index-resolution logic behind `reconcileChapterIndexFromCurrentItem()`.
    /// Extracted so it's unit-testable without a real `AVPlayerItem`/`AVQueuePlayer`.
    ///
    /// Some books produce two "chapters" (e.g. a cover-image placeholder and a
    /// near-empty title page) whose `downloadUrl`s resolve to the exact same
    /// cached/near-silent MP3. `AVQueuePlayer` (with `actionAtItemEnd = .advance`)
    /// only ever moves forward through its items — it never rewinds. Resolving
    /// a duplicate URL with a plain "first match from index 0" always snaps
    /// back to the earlier chapter, which ping-pongs the lock-screen /
    /// Now Playing title between the two every time KVO fires. Searching
    /// forward from `currentIndex` (wrapping only if nothing at/after it
    /// matches) keeps resolution monotonic with the queue's forward-only
    /// advance and eliminates the oscillation.
    ///
    /// Returns `nil` when no chapter's resolved URL matches `currentItemURL`
    /// (mirrors the "not found" case of the instance method).
    nonisolated static func resolveChapterIndex(
        currentIndex: Int,
        chapterURLs: [URL?],
        currentItemURL: URL
    ) -> Int? {
        guard chapterURLs.indices.contains(currentIndex) else { return nil }
        let searchOrder = Array(chapterURLs.indices[currentIndex...]) + Array(chapterURLs.indices[..<currentIndex])
        return searchOrder.first { i in chapterURLs[i] == currentItemURL }
    }

    /// Converts the durable EPUB chapter identity into the temporary queue
    /// offset used by a partial local snapshot. Missing chapters are omitted
    /// from that queue, so using the EPUB index directly would resume the
    /// wrong audio after a relaunch.
    nonisolated static func restoredPlayableChapterOffset(
        snapshot: JobSnapshot,
        persistedEpubChapterIndex: Int
    ) -> Int {
        snapshot.playableChapters.firstIndex { $0.index == persistedEpubChapterIndex } ?? 0
    }

    /// Chapters present in `new` but absent from `old`, keyed by the EPUB-side
    /// chapter index. Pure helper for streaming updates where completion order
    /// can differ from EPUB order because the backend prioritises the chapter
    /// the user is reading first, then wraps around.
    nonisolated static func chaptersToAppend(
        old: [JobSnapshot.Chapter],
        new: [JobSnapshot.Chapter]
    ) -> [JobSnapshot.Chapter] {
        let existing = Set(old.map(\.index))
        return new.filter { !existing.contains($0.index) }
    }

    /// Which `playableChapters` indices changed their `downloadUrl` and are
    /// safe to swap in the queue. A chapter qualifies when it existed in the
    /// old snapshot, its non-nil URL differs in the new snapshot, and it is
    /// strictly ahead of the chapter currently playing (so the live item is
    /// never yanked out from under the playhead). Pure + static + nonisolated
    /// so it is callable from a synchronous test context (AudioPlayer is
    /// @MainActor; this function touches no instance state).
    nonisolated static func chapterIndicesNeedingURLSwap(
        old: [JobSnapshot.Chapter],
        new: [JobSnapshot.Chapter],
        currentlyPlayingIndex: Int
    ) -> [Int] {
        var result: [Int] = []
        let shared = min(old.count, new.count)
        var idx = currentlyPlayingIndex + 1
        while idx < shared {
            let newURL = new[idx].downloadUrl
            if let newURL, !newURL.isEmpty, newURL != old[idx].downloadUrl {
                result.append(idx)
            }
            idx += 1
        }
        return result
    }


    nonisolated static func chapterNavigationIndex(
        currentIndex: Int,
        direction: ChapterNavigationDirection,
        chapterCount: Int
    ) -> Int? {
        guard chapterCount > 0 else { return nil }
        let offset: Int
        switch direction {
        case .backward: offset = -1
        case .forward: offset = 1
        }
        let candidate = currentIndex + offset
        return (0..<chapterCount).contains(candidate) ? candidate : nil
    }


    nonisolated static func shouldAdvanceAtSeekEnd(
        position: TimeInterval,
        duration: TimeInterval,
        tolerance: TimeInterval = 0.75
    ) -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0 else { return false }
        return position >= max(0, duration - tolerance)
    }


    nonisolated static func rateAdjustedDuration(
        seconds: TimeInterval,
        rate: PlaybackRate
    ) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return seconds / TimeInterval(rate.rawValue)
    }

    enum ChapterNavigationDirection {
        case backward
        case forward
    }

    static func nextCanonicalIndex(snapshot: JobSnapshot?, playbackChapters: [JobSnapshot.Chapter],
                                   currentChapterIndex: Int, isSegmentMode: Bool) -> Int? {
        guard let snapshot else { return nil }
        let chapters = playbackChapters.isEmpty ? snapshot.playableChapters : playbackChapters
        let current: Int
        if isSegmentMode {
            current = currentChapterIndex
        } else {
            guard chapters.indices.contains(currentChapterIndex) else { return nil }
            current = chapters[currentChapterIndex].index
        }
        let offset = isSegmentMode ? PlaybackSegmentSession.segmentManifestIndexOffset(snapshot) : 0
        return (snapshot.chapterProgress ?? chapters).map { $0.index - offset }.filter { $0 > current }.min()
    }

    static func chapterValue(snapshot: JobSnapshot?, playbackChapters: [JobSnapshot.Chapter],
                             currentChapterIndex: Int, isSegmentMode: Bool) -> JobSnapshot.Chapter? {
        // SOURCE OF TRUTH: `currentChapterIndex` lives in playable-list
        // space. Resolving against `chapterProgress` by `$0.index ==
        // currentChapterIndex` would match an EPUB-index that happens
        // to share a numeric value with the playable index — wrong
        // chapter whenever any earlier chapter is unplayable. The
        // canonical lookup is `playableChapters[currentChapterIndex]`,
        // and we cross-reference back into `chapterProgress` by EPUB
        // index to surface any extra metadata the playable subset
        // dropped (rare; same struct today).
        if isSegmentMode {
            if let snapshot, snapshot.chapterIndexBase != nil {
                let offset = PlaybackSegmentSession.segmentManifestIndexOffset(snapshot)
                return snapshot.chapterProgress?.first { $0.index == currentChapterIndex + offset }
            }
            return snapshot?.chapterProgress?.first { $0.index == currentChapterIndex + 1 }
                ?? snapshot?.chapterProgress?.first { $0.index == currentChapterIndex }
        }
        let chapters = playbackChapters.isEmpty ? (snapshot?.playableChapters ?? []) : playbackChapters
        guard !chapters.isEmpty,
              chapters.indices.contains(currentChapterIndex) else { return nil }
        let playing = chapters[currentChapterIndex]
        if let progress = snapshot?.chapterProgress,
           let match = progress.first(where: { $0.index == playing.index }) {
            return match
        }
        return playing
    }
    enum Move { case none, segment(Int), seekStart, load(Int), reload(Int), advance }
    static func navigation(direction: ChapterNavigationDirection, snapshot: JobSnapshot?,
                           chapters liveChapters: [JobSnapshot.Chapter], currentIndex: Int,
                           position: TimeInterval, segmentMode: Bool, hasPlayer: Bool) -> Move {
        let chapters = liveChapters.isEmpty ? (snapshot?.playableChapters ?? []) : liveChapters
        if segmentMode {
            switch direction {
            case .forward:
                return nextCanonicalIndex(snapshot: snapshot, playbackChapters: liveChapters,
                                          currentChapterIndex: currentIndex, isSegmentMode: true).map(Move.segment) ?? .none
            case .backward:
                if position > 3 { return .seekStart }
                guard let snapshot else { return .none }
                let offset = PlaybackSegmentSession.segmentManifestIndexOffset(snapshot)
                let previous = (snapshot.chapterProgress ?? []).map { $0.index - offset }
                    .filter { $0 < currentIndex }.max()
                return .segment(previous ?? currentIndex)
            }
        }
        if !hasPlayer {
            guard let snapshot, let index = chapterNavigationIndex(currentIndex: currentIndex,
                direction: direction, chapterCount: snapshot.playableChapters.count) else { return .none }
            return .load(index)
        }
        switch direction {
        case .forward:
            if snapshot != nil, currentIndex + 1 >= chapters.count { return .none }
            return .advance
        case .backward:
            if position > 3 || currentIndex <= 0 { return .seekStart }
            return snapshot == nil ? .seekStart : .reload(currentIndex - 1)
        }
    }

}
