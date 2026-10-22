import AVFoundation
import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Applies confirmed queue facts to clocks, resume/artifact persistence and
/// native publication. It owns no transport intent and grants no autoplay.
@MainActor
final class PlaybackObservation {
    struct State {
        let snapshot: JobSnapshot?
        let isPlaying: Bool
        let isSeeking: Bool
        let segmentMode: Bool
        let rate: PlaybackRate
        let coverArtData: Data?
        static let empty = State(snapshot: nil, isPlaying: false, isSeeking: false,
                                 segmentMode: false, rate: .x100, coverArtData: nil)
    }
    struct Actions {
        let state: () -> State
        let playing: (Bool) -> Void
        let paused: (Bool) -> Void
        let streamingChapter: (Int?) -> Void
        let structuralChange: () -> Void
        let pause: () -> Void
        let resolveURL: (String?, String?, Int?) -> URL?
    }
    private let queueSession: PlaybackQueueSession
    private let segments: PlaybackSegmentSession
    private let chapterSession: PlaybackChapterSession
    private let seeking: PlaybackSeekExecution
    private let navigation: ChapterNavigationDecision
    private let journeys: PlaybackJourneyRecorder
    private let resumePersistence: PlaybackResumeStore
    private let playbackClock: PlaybackClock
    private let broadcast: PlaybackBroadcast
    private let nowPlayingPublication: NowPlayingPublication
    private let sleepTimer: SleepPlaybackTimer
    private let actions: Actions
    init(queue: PlaybackQueueSession, segments: PlaybackSegmentSession, chapters: PlaybackChapterSession,
         seeking: PlaybackSeekExecution, navigation: ChapterNavigationDecision, journeys: PlaybackJourneyRecorder,
         resume: PlaybackResumeStore, clock: PlaybackClock, broadcast: PlaybackBroadcast,
         publication: NowPlayingPublication, sleepTimer: SleepPlaybackTimer, actions: Actions) {
        queueSession = queue
        self.segments = segments
        chapterSession = chapters
        self.seeking = seeking
        self.navigation = navigation
        self.journeys = journeys
        resumePersistence = resume
        playbackClock = clock
        self.broadcast = broadcast
        nowPlayingPublication = publication
        self.sleepTimer = sleepTimer
        self.actions = actions
    }
    private var snapshot: JobSnapshot? { actions.state().snapshot }
    private var isPlaying: Bool { actions.state().isPlaying }
    private var isSeeking: Bool { actions.state().isSeeking }
    private var isSegmentMode: Bool { actions.state().segmentMode }
    private var rate: PlaybackRate { actions.state().rate }
    private var coverArtData: Data? { actions.state().coverArtData }
    private var currentChapterIndex: Int { queueSession.currentChapterIndex }
    private var player: AVQueuePlayer? { queueSession.player }
    private var positionSeconds: TimeInterval {
        get { playbackClock.positionSeconds }
        set { playbackClock.update(positionSeconds: newValue) }
    }
    private var durationSeconds: TimeInterval {
        get { playbackClock.durationSeconds }
        set { playbackClock.update(durationSeconds: newValue) }
    }
    private var playbackPositionSeconds: TimeInterval { PlaybackChapterQueue.rateAdjustedDuration(seconds: positionSeconds, rate: rate) }
    private var playbackDurationSeconds: TimeInterval { PlaybackChapterQueue.rateAdjustedDuration(seconds: durationSeconds, rate: rate) }
    private var nowPlayingState: NowPlayingPublication.State {
        .init(snapshot: snapshot, effectiveChapterTitle: effectiveChapterTitle, positionSeconds: positionSeconds, durationSeconds: durationSeconds, isPlaying: isPlaying, rate: rate, coverArtData: coverArtData, currentChapterIndex: currentChapterIndex, playbackPositionSeconds: playbackPositionSeconds, playbackDurationSeconds: playbackDurationSeconds)
    }
    var playbackChapterURLs: [URL?]? {
        guard let snapshot else { return nil }
        let chapters = chapterSession.chapters.isEmpty ? snapshot.playableChapters : chapterSession.chapters
        return chapters.map {
            actions.resolveURL($0.downloadUrl, snapshot.jobId, $0.index)
        }
    }

    /// Canonical chapter title for every playback surface: mini player,
    /// expanded player, Now Playing, lock screen and widget.
    var effectiveChapterTitle: String {
        navigation.effectiveTitle(snapshot: snapshot, playbackChapters: chapterSession.chapters,
            currentChapterIndex: currentChapterIndex, isSegmentMode: isSegmentMode)
    }
    var currentChapterValue: JobSnapshot.Chapter? {
        PlaybackChapterQueue.chapterValue(snapshot: snapshot, playbackChapters: chapterSession.chapters,
            currentChapterIndex: currentChapterIndex, isSegmentMode: isSegmentMode)
    }

    func requestRetentionForAudibleChapter() {
        resumePersistence.recordAudibleChapter(player: player, snapshot: snapshot, isSegmentMode: isSegmentMode,
            segments: segments, playbackChapters: chapterSession.chapters, currentChapterIndex: currentChapterIndex,
            resolveURL: { self.actions.resolveURL($0, $1, $2) })
    }

    func recordAudibleAudioIfNeeded(renderedSeconds: TimeInterval) {
        journeys.recordAudibleAudioIfNeeded(
            audible: PlaybackJourneyRecorder.hasAudibleOutput(timeControlStatus: player?.timeControlStatus, renderedSeconds: renderedSeconds),
            attach: { self.attachCurrentStreamPublication(to: $0) })
    }

    func attachCurrentStreamPublication(to journeyID: UUID) {
        guard isSegmentMode,
              let asset = player?.currentItem?.asset as? AVURLAsset,
              let identity = PlaybackSegmentSession.segmentIdentityForSegmentItem(asset.url),
              segments.files[identity] == asset.url else { return }
        if let publication = segments.publications[identity] {
            _ = LatencyObservationStore.shared.attachStreamPublication(publication, for: journeyID)
        }
        if let receipt = segments.requestReceipts[identity], receipt.journeyID == journeyID {
            _ = LatencyObservationStore.shared.attachStreamRequest(receipt, for: journeyID)
        }
    }

    // MARK: Observers

    func attachObservers() {
        queueSession.observe(time: { [weak self] in self?.observePlaybackTime($0, from: $1) },
            finished: { [weak self] in self?.handleFinishedItem($0) },
            itemChanged: { [weak self] in
                guard let self else { return }
                // Drop a previous chapter's proportional seek before any new
                // duration may apply it to the wrong text anchor.
                self.seeking.pending.proportional = nil
                let changed = self.queueSession.reconcileChapter(segmentMode: self.isSegmentMode, segments: self.segments, chapterURLs: { self.playbackChapterURLs })
                self.publishCurrentChapter(auto: changed)
                self.updateNowPlayingInfo()
            }, duration: { [weak self] duration in
                guard let self else { return }
                self.durationSeconds = self.isSegmentMode ? self.segments.chapterDuration : duration
                self.seeking.applyPendingProportionalSeek()
                self.updateNowPlayingInfo()
            })
    }

    func observePlaybackTime(_ time: CMTime, from player: AVQueuePlayer) {
        let rawTime = time.seconds.isFinite ? time.seconds : 0
        self.requestRetentionForAudibleChapter()
        self.recordAudibleAudioIfNeeded(renderedSeconds: rawTime)
        queueSession.updateClock(rawTime: rawTime, seeking: isSeeking, segmentMode: isSegmentMode,
            segments: segments, snapshot: { self.snapshot })
        // Item C — fire a queued proportional seek the first
        // tick after AVPlayer publishes duration. Without this
        // a play tap during "From the current page" right after
        // chapter switch lands at 0 (duration was still NaN at
        // call time).
        self.seeking.applyPendingProportionalSeek()
        self.broadcastPosition()
        self.persistResumePoint(force: false)
        self.sleepTimer.tick(player: self.player, pause: { self.actions.pause() })
        // Refresh lock-screen / Control Center scrubber at ~1 Hz.
        // Calling this on every 250ms tick is wasteful; the system
        // only re-renders the widget at ~1 Hz anyway.
        if nowPlayingPublication.shouldPublishTick() { updateNowPlayingInfo() }
    }

    func handleFinishedItem(_ item: AVPlayerItem) {
        switch queueSession.finish(item, segmentMode: isSegmentMode, segments: segments,
            snapshot: { self.snapshot }, chapterCount: {
                self.chapterSession.chapters.isEmpty ? (self.snapshot?.playableChapters.count ?? 0) : self.chapterSession.chapters.count
            }, chapterURLs: { self.playbackChapterURLs }) {
        case .chapterAdvanced:
            publishCurrentChapter(auto: true)
            updateNowPlayingInfo()
        case .ended:
            actions.playing(false)
            actions.paused(false)
            updateNowPlayingInfo()
        case nil: break
        }
    }

    /// Build the Now Playing metadata dict. Extracted from
    /// `updateNowPlayingInfo()` so tests can assert on the metadata
    /// directly: `MPNowPlayingInfoCenter.default().nowPlayingInfo`
    /// does not round-trip reads in a headless xctest host (macOS or
    /// iOS simulator), so asserting through the singleton is flaky.
    func makeNowPlayingInfo() -> [String: Any] { nowPlayingPublication.makeInfo(nowPlayingState) }

    func updateNowPlayingInfo() { nowPlayingPublication.publish(nowPlayingState) }

    func updateReaderChapterTitle(_ title: String, for index: Int) {
        guard !title.isEmpty else { return }
        navigation.updateReaderChapterTitle(title, for: index)
        actions.structuralChange()
    }

    /// Installs every canonical TOC title as soon as the book is parsed.
    /// Conversion and playback can start before a reader controller exists,
    /// so this must not depend on a chapter becoming visible in the reader.
    func updateReaderChapterTitles(_ chapters: [EbookFulltext.Chapter]) {
        if navigation.updateReaderChapterTitles(chapters) { actions.structuralChange() }
    }

    /// Push the current-chapter value to all open AsyncStream
    /// subscribers. The `auto` flag controls whether VoiceOver gets a
    /// spoken announcement of the new chapter title — only true for
    /// auto-advance from the AVQueuePlayer's own auto-advance signal
    /// (KVO + end-of-item notification). User-initiated chapter
    /// changes (play, next, previous, TOC tap) already have the
    /// VoiceOver focus on a control that announces its own state, so
    /// announcing here would cause a double-speak.
    func publishCurrentChapter(auto: Bool = false) {
        let value = currentChapterValue
        actions.streamingChapter(isSegmentMode ? currentChapterIndex : value?.index)
        broadcast.publishChapter(value)
        #if os(iOS)
        if auto, let title = value?.displayTitle, !title.isEmpty {
            UIAccessibility.post(notification: .announcement, argument: title)
        }
        #endif
    }

    func broadcastPosition() {
        broadcast.publishPosition(positionSeconds)
    }

    func persistResumePoint(force: Bool) {
        resumePersistence.persist(snapshot: snapshot, chapterIndex: currentChapterIndex,
            positionSeconds: positionSeconds, isPlaying: isPlaying, force: force)
    }

    func setSegmentChapterEstimate(_ duration: TimeInterval, forChapterIndex chapterIndex: Int) {
        guard duration.isFinite, duration > 0 else { return }
        segments.estimate(duration, chapter: chapterIndex)
        if isSegmentMode, segments.chapterIndex == chapterIndex { durationSeconds = segments.chapterDuration }
    }
}
