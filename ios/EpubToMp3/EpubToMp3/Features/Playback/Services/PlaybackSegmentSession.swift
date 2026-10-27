import Foundation
import AVFoundation
import os.log

/// Owns producer identity, retained segment metadata and bounded deferred audio.
/// Only the coordinator selects an audible item; producer arrivals cannot move
/// this cursor or replace its chapter duration.
@MainActor
final class PlaybackSegmentSession {
    private let log = Logger(subsystem: "epub2mp3", category: "AudioPlayer")
    /// Estimates are kept per chapter. A later buffered chapter must never
    /// overwrite the audible chapter's duration while it is still playing.
    /// Segment metadata is keyed by producer identity rather than arrival
    /// order. Python callbacks may cross MainActor turns; the currently
    /// playing AVPlayerItem remains the source of truth for active state.
    private(set) var files: [SegmentBacklog.Identity: URL] = [:]
    private(set) var durations: [SegmentBacklog.Identity: TimeInterval] = [:]
    private(set) var sentenceIDs: [SegmentBacklog.Identity: String] = [:]
    private(set) var publications: [SegmentBacklog.Identity: LatencyObservation.StreamPublication] = [:]
    private(set) var requestReceipts: [SegmentBacklog.Identity: LatencyObservation.StreamRequestReceipt] = [:]
    private(set) var estimatedDurations: [Int: TimeInterval] = [:]
    private var startingPositions: [Int: TimeInterval] = [:]
    private(set) var chapterIndex = -1
    private(set) var cumulativeBase: TimeInterval = 0
    private(set) var chapterDuration: TimeInterval = 0
    private(set) var activeIdentity: SegmentBacklog.Identity?
    /// Deferred file-backed segments. Entries are never evicted: they are
    /// retained until AVQueuePlayer accepts them or the session is torn down.
    /// The value type keeps ordering + empty-streak behavior
    /// unit-testable without an AVPlayer mock — see
    /// `Services/SegmentBacklog.swift`.
    private var backlog = SegmentBacklog()
    /// Producers wait here when the file-backed deferred queue reaches its
    /// bounded capacity. The continuations resume as AVQueuePlayer accepts
    /// deferred items, so conversion pauses without deleting audio or
    /// accumulating an unbounded number of temporary files.
    private var segmentCapacityWaiters: [(UUID, Int, CheckedContinuation<Bool, Never>)] = []
    var deferredCount: Int { backlog.count }
    var capacityWaiterCount: Int { segmentCapacityWaiters.count }

    func register(_ file: URL, identity: SegmentBacklog.Identity, sentenceID: String?,
                  publication: LatencyObservation.StreamPublication?, receipt: LatencyObservation.StreamRequestReceipt?) {
        files[identity] = file
        if let publication { publications[identity] = publication }
        if let receipt, publication.map({ $0.publicationID == receipt.publicationID }) ?? true {
            requestReceipts[identity] = receipt
        }
        if let sentenceID { sentenceIDs[identity] = sentenceID }
    }
    func remove(_ identity: SegmentBacklog.Identity) {
        files.removeValue(forKey: identity)
        publications.removeValue(forKey: identity)
        requestReceipts.removeValue(forKey: identity)
        sentenceIDs.removeValue(forKey: identity)
    }
    func resetMetadata() {
        files.removeAll()
        durations.removeAll()
        sentenceIDs.removeAll()
        publications.removeAll()
        requestReceipts.removeAll()
        estimatedDurations.removeAll()
        startingPositions.removeAll()
        resetCursor()
    }
    func resetCursor() {
        chapterIndex = -1
        cumulativeBase = 0
        chapterDuration = 0
        activeIdentity = nil
    }
    func activate(_ identity: SegmentBacklog.Identity) -> Bool {
        let changed = chapterIndex != identity.chapterIndex
        if changed {
            chapterIndex = identity.chapterIndex
            cumulativeBase = startingPositions[chapterIndex] ?? 0
            chapterDuration = estimatedDurations[chapterIndex] ?? 0
        }
        activeIdentity = identity
        return changed
    }
    func estimate(_ duration: TimeInterval, chapter: Int, startingRatio: Double = 0) {
        estimatedDurations[chapter] = duration
        startingPositions[chapter] = startingRatio.isFinite ? max(0, min(1, startingRatio)) * duration : 0
        if chapterIndex == chapter { chapterDuration = duration }
    }
    func updateChapterDuration(_ duration: TimeInterval) { chapterDuration = duration }
    func setBase(_ value: TimeInterval) { cumulativeBase = value }
    func advanceBase(_ duration: TimeInterval) { cumulativeBase += duration }
    func recordDuration(_ value: TimeInterval, identity: SegmentBacklog.Identity) { durations[identity] = value }
    func recordEmpty() -> Bool { backlog.recordEmpty() }
    func resetEmptyStreak() { backlog.resetEmptyStreak() }
    func clearDeferred() { _ = backlog.clear() }
    @discardableResult
    func deferSegment(url: URL, chapterIndex: Int, segmentIndex: Int, sentenceId: String?) -> Bool {
        backlog.append(url: url, chapterIndex: chapterIndex, segmentIndex: segmentIndex, sentenceId: sentenceId)
    }
    func drain(into queue: AVQueuePlayer, maximumAhead: Int) -> [AVPlayerItem] {
        guard !backlog.isEmpty else { return [] }
        var inserted: [AVPlayerItem] = []
        while Self.shouldDrainSegmentBacklog(queueCount: queue.items().count, maxQueueAhead: maximumAhead),
              let next = backlog.peekNext() {
            let item = AVPlayerItem(url: next.url)
            if queue.canInsert(item, after: nil) {
                _ = backlog.drainNext()
                queue.insert(item, after: nil)
                inserted.append(item)
            } else {
                // Leave the entry at the front for the next item-end/KVO
                // opportunity. Never consume a segment before insertion.
                break
            }
        }
        resumeWaiters()
        return inserted
    }
    /// Wait until another segment can be accepted without allowing the
    /// deferred file queue to grow without bound. The embedded conversion
    /// bridge calls this before it writes a new temporary MP3.
    func waitForCapacity(
        maximumCount: Int = SegmentBacklog.maximumDeferredSegmentCount
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        let limit = max(1, min(maximumCount, SegmentBacklog.maximumDeferredSegmentCount))
        guard backlog.count >= limit else {
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false) }
                else { segmentCapacityWaiters.append((waiterID, limit, continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.segmentCapacityWaiters.firstIndex(where: { $0.0 == waiterID }) else { return }
                self.segmentCapacityWaiters.remove(at: index).2.resume(returning: false)
            }
        }
    }

    func resumeWaiters() {
        while let first = segmentCapacityWaiters.first,
              backlog.count < first.1 {
            segmentCapacityWaiters.removeFirst().2.resume(returning: true)
        }
    }

    func cancelWaiters() {
        let waiters = segmentCapacityWaiters
        segmentCapacityWaiters.removeAll()
        for (_, _, waiter) in waiters {
            waiter.resume(returning: false)
        }
    }

    func confirmedEnd(for chapterIndex: Int, snapshot: JobSnapshot?) -> TimeInterval? {
        // A stream requested from a page contains only the chapter suffix.
        guard startingPositions[chapterIndex, default: 0] == 0, let snapshot,
              let chapter = (snapshot.chapterProgress ?? snapshot.playableChapters).first(where: {
                  $0.index == chapterIndex + Self.segmentManifestIndexOffset(snapshot)
              }),
              chapter.status == "completed" || snapshot.state == "finished" else { return nil }
        if let duration = chapter.durationSeconds, duration.isFinite, duration > 0 { return duration }
        let retained = files.keys.filter { $0.chapterIndex == chapterIndex }.sorted()
        guard !retained.isEmpty else { return nil }
        var duration: TimeInterval = 0
        for (ordinal, identity) in retained.enumerated() {
            guard identity.segmentIndex == ordinal,
                  let value = durations[identity], value.isFinite, value > 0 else { return nil }
            duration += value
        }
        return duration.isFinite && duration > 0 ? duration : nil
    }

    /// Server chapter indexes are one-based while some older embedded
    /// snapshots are zero-based. Detect the persisted convention instead of
    /// guessing from the playback cursor, so title and queue reconciliation
    /// identify the same chapter on both paths.
    nonisolated static func chapterProgressEntry(
        forSegmentIndex segmentIndex: Int,
        chapterProgress: [JobSnapshot.Chapter]
    ) -> JobSnapshot.Chapter? {
        let usesZeroBasedIndexes = chapterProgress.contains { $0.index == 0 }
        let preferredIndex = usesZeroBasedIndexes ? segmentIndex : segmentIndex + 1
        let alternateIndex = usesZeroBasedIndexes ? segmentIndex + 1 : segmentIndex
        return chapterProgress.first { $0.index == preferredIndex }
            ?? chapterProgress.first { $0.index == alternateIndex }
    }


    nonisolated static func segmentPosition(
        durations: [TimeInterval],
        segmentIndex: Int,
        itemPosition: TimeInterval
    ) -> TimeInterval {
        let base = durations.prefix(max(0, segmentIndex)).reduce(0) { total, duration in
            total + (duration.isFinite && duration > 0 ? duration : 0)
        }
        let position = itemPosition.isFinite ? max(0, itemPosition) : 0
        let duration = durations.indices.contains(segmentIndex) ? durations[segmentIndex] : .infinity
        return base + min(position, duration.isFinite && duration > 0 ? duration : position)
    }


    nonisolated static func segmentDuration(durations: [TimeInterval]) -> TimeInterval {
        durations.filter { $0.isFinite && $0 > 0 }.reduce(0, +)
    }


    nonisolated static func estimatedChapterDurationSeconds(
        wordCount: Int,
        wordsPerMinute: Double = 200
    ) -> TimeInterval {
        guard wordCount > 0, wordsPerMinute.isFinite, wordsPerMinute > 0 else { return 0 }
        return Double(wordCount) / wordsPerMinute * 60
    }


    nonisolated static func segmentChapterTitle(
        chapterIndex: Int,
        chapterProgress: [JobSnapshot.Chapter]
    ) -> String {
        let chapter = chapterProgressEntry(
            forSegmentIndex: chapterIndex,
            chapterProgress: chapterProgress
        )
        return ChapterNavigationDecision.preferredChapterTitle(
            primary: chapter?.name,
            secondary: nil,
            fallback: L10n.string("player.chapter", chapterIndex + 1)
        )
    }


    nonisolated static func segmentProgress(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }


    nonisolated static func segmentRemaining(position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, duration - max(0, position.isFinite ? position : 0))
    }


    nonisolated static func segmentSeekTarget(
        position: TimeInterval,
        durations: [TimeInterval]
    ) -> SegmentSeekTarget? {
        guard !durations.isEmpty, durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        let target = min(segmentDuration(durations: durations), max(0, position.isFinite ? position : 0))
        var base: TimeInterval = 0
        for (index, duration) in durations.enumerated() where duration.isFinite && duration > 0 {
            if target < base + duration || index == durations.count - 1 {
                return SegmentSeekTarget(segmentIndex: index, offset: min(duration, max(0, target - base)))
            }
            base += duration
        }
        return nil
    }


    nonisolated static func shouldDrainSegmentBacklog(queueCount: Int, maxQueueAhead: Int) -> Bool {
        queueCount < max(1, maxQueueAhead)
    }


    nonisolated static func validatedDurationSeconds(
        _ seconds: TimeInterval,
        isReadyToPlay: Bool
    ) -> TimeInterval? {
        guard isReadyToPlay, seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// Embedded synthesis queues files as `ch<N>-seg<M>.mp3`. This is the
    /// authoritative chapter identity while `AVQueuePlayer` advances through
    /// streamed segments, because embedded snapshots have no download URLs.
    nonisolated static func chapterIndexForSegmentItem(_ url: URL) -> Int? {
        segmentIdentityForSegmentItem(url)?.chapterIndex
    }

    /// Decode the stable producer identity from both legacy
    /// `ch<N>-seg<M>.mp3` names and collision-safe session filenames such as
    /// `stream-<uuid>-ch<N>-seg<M>-<uuid>.mp3`.
    nonisolated static func segmentIdentityForSegmentItem(_ url: URL) -> SegmentBacklog.Identity? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count >= 2 else { return nil }
        for index in parts.indices.dropLast() {
            let chapterPart = parts[index]
            let segmentPart = parts[parts.index(after: index)]
            guard chapterPart.hasPrefix("ch"), segmentPart.hasPrefix("seg"),
                  let chapter = Int(chapterPart.dropFirst(2)),
                  let segment = Int(segmentPart.dropFirst(3)) else {
                continue
            }
            return SegmentBacklog.Identity(chapterIndex: chapter, segmentIndex: segment)
        }
        return nil
    }

    struct SegmentSeekTarget: Equatable {
        let segmentIndex: Int
        let offset: TimeInterval
    }

    /// Remote manifests are one-based; legacy snapshots containing chapter
    /// zero remain supported.
    nonisolated static func segmentManifestIndexOffset(_ snapshot: JobSnapshot) -> Int {
        if let base = snapshot.chapterIndexBase, base == 0 || base == 1 { return base }
        return (snapshot.chapterProgress ?? snapshot.playableChapters).contains { $0.index == 0 } ? 0 : 1
    }

    nonisolated static func segmentDuration(_ durations: [TimeInterval]) -> TimeInterval {
        segmentDuration(durations: durations)
    }



    enum Preparation { case accepted, ignored, emptyFailure }
    func prepare(data: Data, identity: SegmentBacklog.Identity, hasPlayer: Bool) -> Preparation {
        let chapterIndex = identity.chapterIndex
        let segmentIndex = identity.segmentIndex
        log.debug("[enqueueSegment] ch=\(chapterIndex) seg=\(segmentIndex) bytes=\(data.count) playerNil=\(!hasPlayer)")
        guard !data.isEmpty else {
            log.warning("[enqueueSegment] empty data ignored ch=\(chapterIndex) seg=\(segmentIndex)")
            // Edge-TTS occasionally emits a zero-byte preamble as the
            // first chunk; that's a normal warmup hiccup, not a user-
            // actionable error. Only surface after N consecutive
            // empties in the same chapter so the alert reflects a
            // real problem (engine misconfigured / network flap), not
            // routine ramp-up.
            if recordEmpty() {
                return .emptyFailure
            }
            return .ignored
        }
        resetEmptyStreak()

        // Retried callbacks must not overwrite a URL that AVFoundation may
        // already be reading, nor enqueue a spoken passage twice.
        guard files[identity] == nil else {
            log.notice("[enqueueSegment] duplicate ignored ch=\(chapterIndex) seg=\(segmentIndex)")
            return .ignored
        }
        return .accepted
    }

    enum Admission {
        case created(AVQueuePlayer)
        case buffered(AVQueuePlayer, highWaterMark: Bool)
        case duplicate
    }
    func admit(_ file: URL, identity: SegmentBacklog.Identity, sentenceID: String?,
               publication: LatencyObservation.StreamPublication?, receipt: LatencyObservation.StreamRequestReceipt?,
               queueSession: PlaybackQueueSession) -> Admission {
        register(file, identity: identity, sentenceID: sentenceID, publication: publication, receipt: receipt)
        guard let queue = queueSession.player else {
            let item = AVPlayerItem(url: file)
            let queue = AVQueuePlayer(items: [item])
            queue.actionAtItemEnd = .advance
            queueSession.mount(queue)
            queueSession.replaceOwnership([ObjectIdentifier(item)])
            return .created(queue)
        }
        guard deferSegment(url: file, chapterIndex: identity.chapterIndex, segmentIndex: identity.segmentIndex,
                           sentenceId: sentenceID) else {
            remove(identity)
            return .duplicate
        }
        return .buffered(queue, highWaterMark: deferredCount == SegmentBacklog.advisoryHighWaterMark)
    }


    func observeDuration(queue: AVQueuePlayer, snapshot: JobSnapshot?) -> TimeInterval {
        for item in queue.items() {
            guard let asset = item.asset as? AVURLAsset,
                  let identity = Self.segmentIdentityForSegmentItem(asset.url),
                  let duration = Self.validatedDurationSeconds(item.duration.seconds, isReadyToPlay: item.status == .readyToPlay)
            else { continue }
            recordDuration(duration, identity: identity)
        }
        chapterDuration = ChapterPlaybackTimeline(
            estimate: estimatedDurations[chapterIndex],
            confirmed: confirmedEnd(for: chapterIndex, snapshot: snapshot)
        ).duration
        return chapterDuration
    }

}
