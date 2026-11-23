import AVFoundation
import Foundation

/// Owns one seek request and its application to the real queue. AudioPlayer
/// supplies current book/intent and remains the only global command entry.
@MainActor
final class PlaybackSeekExecution {
    struct Actions {
        let snapshot: () -> JobSnapshot?
        let segmentMode: () -> Bool
        let isPlaying: () -> Bool
        let seeking: (Bool) -> Void
        let pauseTransport: () -> Void
        let cancelAutoplay: () -> Void
        let play: (JobSnapshot, Int) -> Void
        let resume: () -> Void
        let publish: () -> Void
        let chapterChanged: () -> Void
        let attachPublication: (UUID) -> Void
        let resolveURL: (String?, String, Int) -> URL?
        let chapterURLs: () -> [URL?]?
    }
    let pending: PendingPlaybackSeek
    private let queueSession: PlaybackQueueSession
    private let segments: PlaybackSegmentSession
    private let chapterSession: PlaybackChapterSession
    private let readerSeek: ReaderPlaybackSeek
    private let navigation: ChapterNavigationDecision
    private let journeys: PlaybackJourneyRecorder
    private let clock: PlaybackClock
    private let broadcast: PlaybackBroadcast
    private let actions: Actions
    init(queue: PlaybackQueueSession, segments: PlaybackSegmentSession,
         chapters: PlaybackChapterSession, reader: ReaderPlaybackSeek,
         navigation: ChapterNavigationDecision, journeys: PlaybackJourneyRecorder,
         clock: PlaybackClock, broadcast: PlaybackBroadcast,
         navigationChanged: @escaping (PendingPlaybackSeek.PendingNavigation?) -> Void,
         actions: Actions) {
        pending = PendingPlaybackSeek(navigationChanged: navigationChanged)
        queueSession = queue
        self.segments = segments
        chapterSession = chapters
        readerSeek = reader
        self.navigation = navigation
        self.journeys = journeys
        self.clock = clock
        self.broadcast = broadcast
        self.actions = actions
    }
    private var player: AVQueuePlayer? { queueSession.player }
    private var snapshot: JobSnapshot? { actions.snapshot() }
    private var isSegmentMode: Bool { actions.segmentMode() }
    private var isPlaying: Bool { actions.isPlaying() }
    private var currentChapterIndex: Int { queueSession.currentChapterIndex }
    private var durationSeconds: TimeInterval { clock.durationSeconds }
    private var positionSeconds: TimeInterval {
        get { clock.positionSeconds }
        set { clock.update(positionSeconds: newValue) }
    }
    func cancel() {
        pending.cancel()
        actions.seeking(false)
        journeys.cancelSeek()
    }

    func restoreListeningSeek(_ request: PendingPlaybackSeek.ChapterRequest, jobID: String) {
        guard snapshot?.jobId == jobID else { return }
        begin()
        pending.chapter = .init(id: request.id, jobID: jobID, chapterIndex: request.chapterIndex,
            autoplay: request.autoplay, position: request.position, startsAtGeneratedOrigin: request.startsAtGeneratedOrigin,
            navigationTarget: request.navigationTarget ?? .chapterTime(request.position),
            relativeSkip: request.relativeSkip)
        queueSession.selectChapter(request.chapterIndex)
        actions.seeking(true)
        actions.pauseTransport()
        positionSeconds = request.position
        broadcast.publishPosition(positionSeconds)
        actions.publish()
    }
    private func begin() {
        cancel()
        journeys.beginSeekJourney()
    }
    private func complete() {
        journeys.completeSeekJourney(attach: actions.attachPublication)
    }

    /// "From the current page" branch of the divergence dialog. Loads
    /// the snapshot at the reader's chapter, then seeks (in priority
    /// order):
    /// 1. **`sentenceId`** + injected timing → precise per-sentence
    ///    seek using `SentenceSyncEngine`-grade data.
    /// 2. **`sentenceOffsetRatio`** + known `durationSeconds` →
    ///    char-uniform approximation.
    /// 3. **fallback** → seek to 0 (chapter start).
    ///
    /// The seek can be issued *before* `durationSeconds` is published
    /// (AVPlayer reports it asynchronously after asset preparation).
    /// For the ratio path we therefore stash a pending seek that fires
    /// when the duration finally lands — see `applyPendingProportionalSeek`.
    func startFromReaderPage(
        _ readerChapterIndex: Int, sentenceId: String? = nil,
        sentenceOffsetRatio: Double? = nil, sentenceWordOffsetRatio: Double? = nil
    ) {
        navigation.rememberReaderPlaybackAnchor()
        let plan = readerSeek.plan(chapter: readerChapterIndex, sentenceID: sentenceId,
            ratio: sentenceOffsetRatio, wordRatio: sentenceWordOffsetRatio, snapshot: snapshot,
            hasPlayer: player != nil, segmentMode: isSegmentMode, segments: segments, navigation: navigation)
        switch plan {
        case .resume: actions.resume()
        case .pending(let request, let waiting):
            pending.proportional = nil
            if waiting { actions.cancelAutoplay() }
            begin()
            pending.chapter = request
            actions.seeking(true)
            actions.pauseTransport()
            if !waiting { applyPending() }
            actions.publish()
        case .chapter(let target, let anchor):
            guard let snapshot else { return }
            actions.play(snapshot, target)
            switch anchor {
            case .sentence(let position):
                seek(to: position)
                pending.proportional = nil
            case .ratio(let ratio):
                if durationSeconds > 0 {
                    seek(to: max(0, min(1, ratio)) * durationSeconds)
                    pending.proportional = nil
                } else { pending.proportional = .init(ratio: ratio, jobID: snapshot.jobId, forChapterIndex: target) }
            case .beginning:
                seek(to: 0)
                pending.proportional = nil
            }
            actions.resume()
        }
    }

    /// Pending fractional-position seek waiting for `durationSeconds`.
    /// to be published by the asset prepare. Scoped to its job and chapter
    /// so a late duration cannot apply it to another book or chapter.

    /// Called from the periodic time observer when `durationSeconds`
    /// transitions to a positive value. Applies only when the player
    /// is still on the chapter the seek was queued for; otherwise the
    /// pending seek is dropped (the queue advanced past it).
    func applyPendingProportionalSeek() {
        guard let position = pending.proportionalPosition(jobID: snapshot?.jobId,
            chapterIndex: currentChapterIndex, duration: durationSeconds) else { return }
        seek(to: position)
        pending.proportional = nil
    }

    func skip(by delta: TimeInterval) {
        guard delta.isFinite, let snapshot, let player else { return }
        let previous = pending.chapter.flatMap { $0.jobID == snapshot.jobId ? $0 : nil }
        var origin = previous?.position ?? positionSeconds
        if !isSegmentMode, previous == nil, pending.activeID == nil, let item = player.currentItem {
            _ = queueSession.reconcileChapter(segmentMode: false, segments: segments, chapterURLs: actions.chapterURLs)
            let itemTime = item.currentTime().seconds
            if itemTime.isFinite, itemTime >= 0 { origin = itemTime }
        }
        let current = PlaybackChapterQueue.chapterValue(snapshot: snapshot,
            playbackChapters: chapterSession.chapters, currentChapterIndex: currentChapterIndex,
            isSegmentMode: isSegmentMode)
        guard let index = previous?.chapterIndex ?? (isSegmentMode ? currentChapterIndex : current?.index) else { return }
        let time = origin + delta
        guard time.isFinite else { return }
        clock.audioOutput.clear()
        if !isSegmentMode, previous == nil, time >= 0,
           let duration = player.currentItem?.duration.seconds, duration.isFinite, time < duration {
            seek(to: time, advanceAtEnd: false)
            return
        }
        let autoplay = previous?.autoplay ?? pending.autoplay ?? isPlaying
        begin()
        // A backward skip can land before the audio this job generated (it started mid-chapter, or earlier
        // segments were released): waiting for it would load forever. Carry the estimated text position so the
        // resolver can promote the request to a restart from there ("approximate time") once it finds the target
        // is not retained. Targets inside the retained audio still seek inside it.
        let approximate = isSegmentMode && delta < 0 && time >= 0 && durationSeconds > 0
            ? min(1, time / durationSeconds) : nil
        pending.chapter = .init(id: UUID(), jobID: snapshot.jobId, chapterIndex: index,
                                autoplay: autoplay, position: time, approximateRatio: approximate,
                                relativeSkip: true)
        actions.seeking(true)
        actions.pauseTransport()
        applyPending()
        if isSegmentMode, let request = pending.chapter, request.chapterIndex == currentChapterIndex {
            positionSeconds = max(0, request.position)
            broadcast.publishPosition(positionSeconds)
        }
        actions.publish()
    }

    func seek(to seconds: TimeInterval, allowsApproximation: Bool = false, advanceAtEnd: Bool = true) {
        let requested = seconds.isFinite ? max(0, seconds) : 0
        let confirmedEnd = isSegmentMode ? confirmedSegmentChapterEnd(for: currentChapterIndex) : nil
        let target = confirmedEnd.map { min($0, requested) } ?? requested
        let autoplay = pending.chapter?.autoplay ?? pending.autoplay ?? isPlaying
        begin()
        if advanceAtEnd, (!isSegmentMode || confirmedEnd != nil),
           PlaybackChapterQueue.shouldAdvanceAtSeekEnd(position: target, duration: confirmedEnd ?? durationSeconds),
           let snapshot, let nextIndex = nextCanonicalChapterIndex {
            pending.chapter = PendingPlaybackSeek.ChapterRequest(
                id: UUID(), jobID: snapshot.jobId, chapterIndex: nextIndex,
                autoplay: autoplay
            )
            actions.seeking(true)
            actions.pauseTransport()
            applyPending()
            actions.publish()
            return
        }
        if isSegmentMode, let snapshot {
            pending.chapter = PendingPlaybackSeek.ChapterRequest(
                id: UUID(), jobID: snapshot.jobId, chapterIndex: currentChapterIndex,
                autoplay: autoplay, position: target,
                allowsFinalEndpoint: confirmedEnd.map { target >= $0 } == true
                    && nextCanonicalChapterIndex == nil,
                approximateRatio: allowsApproximation && durationSeconds > 0
                    ? min(1, target / durationSeconds) : nil
            )
            actions.seeking(true)
            actions.pauseTransport()
            positionSeconds = target
            broadcast.publishPosition(positionSeconds)
            applyPending()
            actions.publish()
            return
        }
        positionSeconds = target
        broadcast.publishPosition(positionSeconds)
        actions.publish()
        guard let player else { return }

        actions.seeking(true)
        pending.performSeek(to: target, player: player, autoplay: autoplay) { [weak self] finished, shouldResume in
            guard let self else { return }
            self.actions.seeking(false)
            // Preserve the selected target until the first confirmed clock tick.
            self.positionSeconds = target
            self.broadcast.publishPosition(self.positionSeconds)
            self.actions.publish()
            if finished {
                self.complete()
                if shouldResume && !self.isPlaying { self.actions.resume() }
            } else { self.cancel() }
        }
    }

    /// Pending navigation uses segment indexes while streaming and manifest
    /// indexes for full files, never offsets in the filtered playable list.
    private var nextCanonicalChapterIndex: Int? {
        PlaybackChapterQueue.nextCanonicalIndex(snapshot: snapshot, playbackChapters: chapterSession.chapters,
            currentChapterIndex: currentChapterIndex, isSegmentMode: isSegmentMode)
    }

    /// Estimates describe progress, not proof that no more audio will arrive.
    private func confirmedSegmentChapterEnd(for chapterIndex: Int) -> TimeInterval? {
        segments.confirmedEnd(for: chapterIndex, snapshot: snapshot)
    }

    func applyPending() {
        pending.resolve(snapshot: { [weak self] in self?.snapshot },
            hasPlayer: player != nil, isSegmentMode: isSegmentMode, segments: segments,
            resolveURL: { [weak self] path, job, chapter in
                self?.actions.resolveURL(path, job, chapter)
            }, selectChapters: { self.chapterSession.adopt($0) },
            retry: { [weak self] in self?.applyPending() },
            cancel: { [weak self] in self?.cancel() },
            waiting: { [weak self] in
                guard let self, self.pending.chapter?.jobID == self.snapshot?.jobId else { return }
                if self.pending.requestApproximateStart() { return }
                self.queueSession.player?.pause()
                self.queueSession.player?.removeAllItems()
                self.queueSession.clearOwnership()
                self.segments.clearDeferred()
                self.segments.resumeWaiters()
            },
            rebuild: { [weak self] request, entries, offset, base in
                self?.rebuild(request, entries: entries, offset: offset, base: base)
            })
    }

    private func rebuild(
        _ request: PendingPlaybackSeek.ChapterRequest, entries: [(URL, SegmentBacklog.Identity?)],
        offset: TimeInterval, base: TimeInterval
    ) {
        pending.rebuild(request, entries: entries, offset: offset, base: base,
            queueSession: queueSession, segments: segments, isSegmentMode: isSegmentMode,
            maximumAhead: PlaybackQueueSession.maximumAhead, prepared: { base, position in
                _ = self.queueSession.reconcileChapter(segmentMode: self.isSegmentMode, segments: self.segments,
                    chapterURLs: self.actions.chapterURLs)
                if self.isSegmentMode { self.segments.setBase(base) }
                self.positionSeconds = position
            }, completed: { [weak self] current in
                guard let self else { return }
                self.actions.seeking(false)
                self.positionSeconds = current.position
                self.complete()
                self.actions.chapterChanged()
                if current.autoplay { self.actions.resume() }
                self.broadcast.publishPosition(self.positionSeconds)
                self.actions.publish()
            }, failed: { [weak self] in self?.cancel() })
    }

    func navigateToSegmentChapter(_ chapterIndex: Int) {
        guard let snapshot else { return }
        let autoplay = pending.chapter?.autoplay ?? pending.autoplay ?? isPlaying
        begin()
        pending.chapter = PendingPlaybackSeek.ChapterRequest(id: UUID(), jobID: snapshot.jobId,
                                               chapterIndex: chapterIndex, autoplay: autoplay)
        actions.seeking(true)
        actions.pauseTransport()
        applyPending()
        actions.publish()
    }

}
