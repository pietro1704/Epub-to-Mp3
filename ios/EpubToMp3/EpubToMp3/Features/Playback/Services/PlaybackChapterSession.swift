import Foundation
import AVFoundation

/// Owns mounted full-chapter queue order and the requested start before files
/// exist. Snapshot display ordering never overwrites arrival order of live audio.
@MainActor
final class PlaybackChapterSession {
    /// Requested playable-list index from the last `play(snapshot:)`
    /// call that arrived before any MP3 URL existed. When the first
    /// playable snapshot lands via SSE, `updateSnapshot` uses this to
    /// build the queue at the same requested starting point instead of
    /// defaulting back to chapter 0.
    /// Queue-order chapter list backing the currently-mounted AVQueuePlayer.
    /// `JobSnapshot.playableChapters` is sorted by EPUB index, which is right
    /// for library/TOC display but wrong for on-demand streaming when the
    /// backend starts at chapter N and later wraps to 0. This list preserves
    /// the actual append order of the live queue.

    private(set) var chapters: [JobSnapshot.Chapter] = []
    private(set) var pendingStartIndex: Int?
    func clear() { chapters.removeAll() }
    func adopt(_ chapters: [JobSnapshot.Chapter]) { self.chapters = chapters }
    func awaitStart(_ index: Int?) { pendingStartIndex = index }

    func install(snapshot: JobSnapshot, startingAt chapterIndex: Int, queueSession: PlaybackQueueSession,
                 resolveURL: (String?, String, Int) -> URL?) -> AVQueuePlayer? {
        let chapters = snapshot.playableChapters
        let safeIndex = max(0, min(chapterIndex, chapters.count - 1))
        guard !chapters.isEmpty else {
            pendingStartIndex = max(0, chapterIndex)
            return nil
        }
        pendingStartIndex = nil
        self.chapters = chapters
        // Build the queue starting AT `safeIndex` rather than building
        // the full list and walking `advanceToNextItem()` to skip
        // forward. For a 200-chapter book jumping to chapter 150 the
        // old approach allocated 150 AVPlayerItems and fired 150 KVO
        // ticks on `currentItem` before any audio played; the slice
        // approach allocates the 50 items we actually need and is O(1).
        let items = chapters[safeIndex...].compactMap { chapter -> AVPlayerItem? in
            guard let url = resolveURL(chapter.downloadUrl, snapshot.jobId, chapter.index) else { return nil }
            return AVPlayerItem(url: url)
        }
        guard !items.isEmpty else { return nil }
        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        queueSession.mount(queue)
        queueSession.replaceOwnership(Set(items.map { ObjectIdentifier($0) }))
        return queue
    }

    func reconcile(previousSnapshot: JobSnapshot?, newSnapshot: JobSnapshot,
                   currentChapterIndex: Int, queue: AVQueuePlayer, queueSession: PlaybackQueueSession,
                   resolveURL: (String?, String, Int) -> URL?) {
        let oldChapters = chapters.isEmpty ? (previousSnapshot?.playableChapters ?? []) : chapters
        let newChapters = newSnapshot.playableChapters
        // Replace future chapters whose file URL changed (re-synthesis). The
        // decision is pure so it can be unit-tested; applying it walks the
        // live queue to find the item to swap without touching the playhead.
        let canSafelySwapByPosition = oldChapters.indices.allSatisfy { idx in
            idx < newChapters.count && oldChapters[idx].index == newChapters[idx].index
        }
        if canSafelySwapByPosition {
            let indicesToReplace = PlaybackChapterQueue.chapterIndicesNeedingURLSwap(
                old: oldChapters,
                new: newChapters,
                currentlyPlayingIndex: currentChapterIndex
            )
            for chapterIdx in indicesToReplace {
                replaceQueuedItem(atChapterIndex: chapterIdx, in: queue, chapters: newChapters, currentChapterIndex: currentChapterIndex, jobID: newSnapshot.jobId, queueSession: queueSession, resolveURL: resolveURL)
            }
        }

        // Append every chapter whose EPUB index was not already queued.
        // Count-based suffix appends break when on-demand streaming starts
        // in the middle of a book and later wraps to earlier EPUB indices:
        // sorted playableChapters become [0, 10, 11] after [10, 11], so
        // `suffix(1)` would duplicate 11 and drop 0. Identity-based diffing
        // preserves the live queue while accepting out-of-order arrivals.
        let chaptersToAppend = PlaybackChapterQueue.chaptersToAppend(old: oldChapters, new: newChapters)
        for chapter in chaptersToAppend {
            guard let absolute = resolveURL(chapter.downloadUrl,
                                              newSnapshot.jobId,
                                              chapter.index) else { continue }
            let item = AVPlayerItem(url: absolute)
            if queue.canInsert(item, after: nil) {
                queue.insert(item, after: nil)
                queueSession.register(ObjectIdentifier(item))
                chapters.append(chapter)
            }
        }

    }

    /// Swap the queued AVPlayerItem for `chapterIndex` (an index into
    /// `playableChapters`) with a fresh item built from its current URL.
    /// The queue holds items from `currentChapterIndex` onward, so the queue
    /// offset is `chapterIndex - currentChapterIndex`. No-ops defensively if
    /// the offset, URL, or AVQueuePlayer insertion constraints don't line up —
    /// the item is simply left as-is rather than risking a playhead glitch.
    private func replaceQueuedItem(
        atChapterIndex chapterIndex: Int,
        in queue: AVQueuePlayer,
        chapters: [JobSnapshot.Chapter], currentChapterIndex: Int, jobID: String,
        queueSession: PlaybackQueueSession, resolveURL: (String?, String, Int) -> URL?
    ) {
        let queueOffset = chapterIndex - currentChapterIndex
        let items = queue.items()
        guard queueOffset > 0, queueOffset < items.count else { return }
        guard chapterIndex < chapters.count,
              let absolute = resolveURL(chapters[chapterIndex].downloadUrl,
                                          jobID,
                                          chapters[chapterIndex].index) else { return }
        let stale = items[queueOffset]
        let anchor = items[queueOffset - 1]
        let fresh = AVPlayerItem(url: absolute)
        queue.remove(stale)
        queueSession.removeOwnership(ObjectIdentifier(stale))
        if queue.canInsert(fresh, after: anchor) {
            queue.insert(fresh, after: anchor)
            queueSession.register(ObjectIdentifier(fresh))
        }
    }
    enum SnapshotUpdate {
        case waiting
        case finishPendingSeek
        case initialQueue(Int, PendingPlaybackSeek.ProportionalRequest?)
        case segmentQueue
        case reconcileQueue
    }
    func updatePlan(snapshot: JobSnapshot, hasPlayer: Bool, segmentMode: Bool,
                    currentChapterIndex: Int, pendingSeek: PendingPlaybackSeek) -> SnapshotUpdate {
        guard hasPlayer else {
            // A first completed file continues the user's existing intent;
            // opening a book and conversion alone never grant autoplay.
            guard !snapshot.playableChapters.isEmpty else { return .waiting }
            if pendingSeek.chapter?.jobID == snapshot.jobId { return .finishPendingSeek }
            return .initialQueue(pendingStartIndex ?? currentChapterIndex, pendingSeek.proportional)
        }
        // Full files must not replay audio already queued segment by segment.
        return segmentMode ? .segmentQueue : .reconcileQueue
    }

}
