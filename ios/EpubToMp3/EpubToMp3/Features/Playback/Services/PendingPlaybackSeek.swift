import Foundation
import AVFoundation

/// Owns pending seek identity, requested autoplay, and asynchronous duration
/// resolution. Queue mutations are emitted to AudioPlayer only after identity
/// is rechecked; stale duration completions cannot commit another request.
@MainActor
final class PendingPlaybackSeek {
    struct ChapterRequest {
        let id: UUID
        let jobID: String
        let chapterIndex: Int
        var autoplay: Bool
        var position: TimeInterval = 0
        var readerPageRatio: Double? = nil
        var allowsFinalEndpoint = false
        var isApplying = false
    }

    struct ProportionalRequest {
        let ratio: Double
        let jobID: String
        let forChapterIndex: Int
    }

    var activeID: UUID?
    var autoplay: Bool?
    var proportional: ProportionalRequest?
    var chapter: ChapterRequest? {
        didSet { navigationChanged(chapter.map { .init(requestID: $0.id, jobID: $0.jobID, chapterIndex: $0.chapterIndex) }) }
    }
    private var durationTask: Task<Void, Never>?
    private let navigationChanged: (PendingNavigation?) -> Void
    init(navigationChanged: @escaping (PendingNavigation?) -> Void) {
        self.navigationChanged = navigationChanged
    }
    func cancel() {
        durationTask?.cancel()
        durationTask = nil
        chapter = nil
        activeID = nil
        autoplay = nil
    }
    func resolve(snapshot currentSnapshot: @escaping () -> JobSnapshot?,
                 hasPlayer: Bool, isSegmentMode: Bool, segments: PlaybackSegmentSession,
                 resolveURL: @escaping (String?, String, Int) -> URL?,
                 selectChapters: ([JobSnapshot.Chapter]) -> Void,
                 retry: @escaping () -> Void, cancel: @escaping () -> Void,
                 rebuild: @escaping (ChapterRequest, [(URL, SegmentBacklog.Identity?)], TimeInterval, TimeInterval) -> Void) {
        guard var pending = chapter, !pending.isApplying,
              let snapshot = currentSnapshot(), snapshot.jobId == pending.jobID, hasPlayer else { return }
        if let ratio = pending.readerPageRatio {
            if isSegmentMode {
                guard let duration = segments.confirmedEnd(for: pending.chapterIndex, snapshot: currentSnapshot())
                    ?? segments.estimatedDurations[pending.chapterIndex], duration > 0 else { return }
                pending.position = ratio * duration
                pending.readerPageRatio = nil
                self.chapter = pending
            } else {
                guard let chapter = snapshot.playableChapters.first(where: { $0.index == pending.chapterIndex }),
                      let url = resolveURL(chapter.downloadUrl,
                          snapshot.jobId, chapter.index) else { return }
                pending.isApplying = true
                self.chapter = pending
                durationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let time = try? await AVURLAsset(url: url).load(.duration)
                    guard !Task.isCancelled, var current = self.chapter,
                          current.id == pending.id else { return }
                    guard let time,
                          let duration = PlaybackSegmentSession.validatedDurationSeconds(time.seconds, isReadyToPlay: true) else {
                        cancel()
                        return
                    }
                    current.position = ratio * duration
                    current.readerPageRatio = nil
                    current.isApplying = false
                    self.chapter = current
                    retry()
                }
                return
            }
        }
        let entries: [(URL, SegmentBacklog.Identity?)]
        if isSegmentMode {
            let retained = segments.files.filter { $0.key.chapterIndex >= pending.chapterIndex }
                .sorted { $0.key < $1.key }
            guard retained.first?.key.chapterIndex == pending.chapterIndex else { return }
            if pending.position > 0 {
                pending.isApplying = true
                self.chapter = pending
                // Load real durations without blocking the main actor. Request
                // identity fences every await against replacement or teardown.
                durationTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    var durations: [TimeInterval] = []
                    var total: TimeInterval = 0
                    for (identity, url) in retained where identity.chapterIndex == pending.chapterIndex {
                        guard !Task.isCancelled, self.chapter?.id == pending.id else { return }
                        // Missing ordinal durations cannot be treated as zero.
                        // A sparse prefix waits for its gap or full-file handoff.
                        guard identity.segmentIndex == durations.count else { break }
                        let duration: TimeInterval
                        if let cached = segments.durations[identity] {
                            duration = cached
                        } else {
                            do {
                                let time = try await AVURLAsset(url: url).load(.duration)
                                guard !Task.isCancelled, self.chapter?.id == pending.id else { return }
                                guard let value = PlaybackSegmentSession.validatedDurationSeconds(time.seconds, isReadyToPlay: true) else {
                                    cancel()
                                    return
                                }
                                duration = value
                                segments.recordDuration(value, identity: identity)
                            } catch {
                                guard self.chapter?.id == pending.id else { return }
                                cancel()
                                return
                            }
                        }
                        durations.append(duration)
                        total += duration
                        if total > pending.position { break }
                    }
                    guard !Task.isCancelled, var resolved = self.chapter,
                          resolved.id == pending.id else { return }
                    // Confirmation may arrive while duration loading is suspended.
                    // Reconcile the existing request, preserving its identity and intent.
                    if let end = segments.confirmedEnd(for: resolved.chapterIndex, snapshot: currentSnapshot()),
                       resolved.position >= end {
                        resolved.position = end
                        resolved.allowsFinalEndpoint = true
                        self.chapter = resolved
                    }
                    // Do not silently clamp a target whose segment has not
                    // arrived yet. Enqueue retries this pending request.
                    if total < resolved.position
                        || (total == resolved.position && !resolved.allowsFinalEndpoint) {
                        self.chapter?.isApplying = false
                        self.durationTask = nil
                        if segments.files.keys.filter({ $0.chapterIndex == pending.chapterIndex }).count
                            > retained.filter({ $0.key.chapterIndex == pending.chapterIndex }).count {
                            retry()
                        }
                        return
                    }
                    guard let target = PlaybackSegmentSession.segmentSeekTarget(position: resolved.position, durations: durations) else { return }
                    let chapterEntries = retained.filter { $0.key.chapterIndex == pending.chapterIndex }
                    let identity = chapterEntries[target.segmentIndex].key
                    let entries = segments.files.filter { $0.key >= identity }
                        .sorted { $0.key < $1.key }.map { ($0.value, Optional($0.key)) }
                    rebuild(pending, entries, target.offset, durations.prefix(target.segmentIndex).reduce(0, +))
                }
                return
            }
            entries = retained.map { ($0.value, $0.key) }
        } else {
            let chapters = snapshot.playableChapters.sorted { $0.index < $1.index }
            guard let targetOffset = chapters.firstIndex(where: { $0.index == pending.chapterIndex }) else { return }
            let available = chapters[targetOffset...].compactMap { chapter -> (URL, SegmentBacklog.Identity?)? in
                guard let url = resolveURL(chapter.downloadUrl,
                                            snapshot.jobId, chapter.index) else { return nil }
                return (url, nil)
            }
            guard let targetURL = resolveURL(chapters[targetOffset].downloadUrl,
                                               snapshot.jobId, pending.chapterIndex),
                  available.first?.0 == targetURL else { return }
            selectChapters(chapters)
            entries = available
        }
        rebuild(pending, entries, pending.position, 0)
    }

    struct PendingNavigation: Equatable {
        let requestID: UUID
        let jobID: String
        let chapterIndex: Int
    }
    func proportionalPosition(jobID: String?, chapterIndex: Int, duration: TimeInterval) -> TimeInterval? {
        guard let pending = proportional else { return nil }
        guard pending.jobID == jobID, pending.forChapterIndex == chapterIndex else {
            // Discard invalid ownership before waiting for asset duration.
            proportional = nil
            return nil
        }
        guard duration > 0 else { return nil }
        return max(0, min(1, pending.ratio)) * duration
    }


    func rebuild(
        _ request: ChapterRequest,
        entries: [(URL, SegmentBacklog.Identity?)],
        offset: TimeInterval,
        base: TimeInterval, queueSession: PlaybackQueueSession,
        segments: PlaybackSegmentSession, isSegmentMode: Bool, maximumAhead: Int,
        prepared: (TimeInterval, TimeInterval) -> Void,
        completed: @escaping (ChapterRequest) -> Void, failed: @escaping () -> Void
    ) {
        // Pause/resume can change intent while duration loading is suspended.
        // Always adopt the current request rather than its pre-await copy.
        guard var pending = chapter, pending.id == request.id,
              let queue = queueSession.player else { return }
        guard !entries.isEmpty else { return }
        pending.isApplying = true
        chapter = pending
        let seekID = UUID()
        activeID = seekID
        // Rebuild in document order. Walking the arrival-ordered queue can
        // consume a later chapter before the requested one. Segment files
        // remain retained; the target may live outside the bounded live queue.
        queue.removeAllItems()
        queueSession.clearOwnership()
        if isSegmentMode { segments.clearDeferred() }
        for (url, identity) in entries {
            if let identity, queue.items().count >= maximumAhead {
                segments.deferSegment(url: url, chapterIndex: identity.chapterIndex,
                               segmentIndex: identity.segmentIndex,
                               sentenceId: segments.sentenceIDs[identity])
            } else {
                let item = AVPlayerItem(url: url)
                queue.insert(item, after: nil)
                queueSession.register(ObjectIdentifier(item))
            }
        }
        guard let targetItem = queue.currentItem else {
            failed()
            return
        }
        segments.resumeWaiters()
        prepared(base, pending.position)
        queue.seek(to: CMTime(seconds: offset, preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, let current = self.chapter,
                      current.id == pending.id, self.activeID == seekID else { return }
                guard finished, queueSession.player?.currentItem === targetItem else {
                    failed()
                    return
                }
                self.chapter = nil
                self.activeID = nil
                completed(current)
            }
        }
    }

    func performSeek(to target: TimeInterval, player: AVQueuePlayer, autoplay: Bool,
                     completed: @escaping (Bool, Bool) -> Void) {
        let seekID = UUID()
        activeID = seekID
        self.autoplay = autoplay
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.activeID == seekID else { return }
                let shouldResume = self.autoplay == true
                self.activeID = nil
                self.autoplay = nil
                completed(finished, shouldResume)
            }
        }
    }

    enum FullFileHandoff {
        case unrelated
        case waiting(terminal: Bool)
        case ready(playableOffset: Int, request: ChapterRequest)
    }
    func fullFileHandoff(snapshot: JobSnapshot, segmentMode: Bool) -> FullFileHandoff {
        guard let pending = chapter, pending.jobID == snapshot.jobId else { return .unrelated }
        let targetIndex = pending.chapterIndex
            + (segmentMode ? PlaybackSegmentSession.segmentManifestIndexOffset(snapshot) : 0)
        guard let target = snapshot.playableChapters.firstIndex(where: { $0.index == targetIndex }) else {
            return .waiting(terminal: snapshot.isTerminal)
        }
        let request = ChapterRequest(id: pending.id, jobID: pending.jobID, chapterIndex: targetIndex,
                                     autoplay: pending.autoplay, position: pending.position,
                                     readerPageRatio: pending.readerPageRatio)
        return .ready(playableOffset: target, request: request)
    }

}
