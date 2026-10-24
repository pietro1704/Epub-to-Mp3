import AVFoundation
import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Executes transport commands against the current queue or speech adapter.
/// AudioPlayer supplies and publishes authoritative user intent; this owner
/// never creates a generation or a second player session.
@MainActor
final class PlaybackTransportCommands {
    struct State {
        let snapshot: JobSnapshot?
        let isPlaying: Bool
        let isSegmentMode: Bool
        let isUsingSpeechFallback: Bool
        let rate: PlaybackRate
    /// Set by `prepareSegmentRestart` (and any future "play tap before
    /// segments arrive" surface) so the next `enqueueSegment` call
    /// flips the queue from rate 0 → rate.rawValue automatically,
    /// without waiting for a second user tap on the transport bar.
        let pendingAutoplay: Bool
        let pendingResumePosition: TimeInterval?
        static let empty = State(snapshot: nil, isPlaying: false, isSegmentMode: false,
                                 isUsingSpeechFallback: false, rate: .x100, pendingAutoplay: false, pendingResumePosition: nil)
    }
    struct Actions {
        let state: () -> State
        let autoplay: (Bool) -> Void
        let playing: (Bool) -> Void
        let paused: (Bool) -> Void
        let speech: (Bool) -> Void
        let rate: (PlaybackRate) -> Void
        let play: (JobSnapshot, Int, Bool) -> Void
        let publish: () -> Void
        let chapterChanged: () -> Void
        let observe: () -> Void
        let activate: (AVQueuePlayer) -> Void
        let clearResumePosition: () -> Void
        let chapterURLs: () -> [URL?]?
    }
    private let queueSession: PlaybackQueueSession
    private let segments: PlaybackSegmentSession
    private let chapterSession: PlaybackChapterSession
    private let seeking: PlaybackSeekExecution
    private let systemPlayback: PlaybackSystemSession
    private let speechFallback: SpeechFallbackPlayer
    private let navigation: ChapterNavigationDecision
    private let journeys: PlaybackJourneyRecorder
    private let resumePersistence: PlaybackResumeStore
    private let clock: PlaybackClock
    private let broadcast: PlaybackBroadcast
    private let actions: Actions
    private let log = Logger(subsystem: "epub2mp3", category: "AudioPlayer")
    init(queue: PlaybackQueueSession, segments: PlaybackSegmentSession, chapters: PlaybackChapterSession,
         seeking: PlaybackSeekExecution, system: PlaybackSystemSession, speech: SpeechFallbackPlayer,
         navigation: ChapterNavigationDecision, journeys: PlaybackJourneyRecorder,
         resume: PlaybackResumeStore, clock: PlaybackClock, broadcast: PlaybackBroadcast, actions: Actions) {
        queueSession = queue
        self.segments = segments
        chapterSession = chapters
        self.seeking = seeking
        systemPlayback = system
        speechFallback = speech
        self.navigation = navigation
        self.journeys = journeys
        resumePersistence = resume
        self.clock = clock
        self.broadcast = broadcast
        self.actions = actions
    }
    private var snapshot: JobSnapshot? { actions.state().snapshot }
    private var isSegmentMode: Bool { actions.state().isSegmentMode }
    private var isPlaying: Bool {
        get { actions.state().isPlaying }
        set { actions.playing(newValue) }
    }
    private var isUsingSpeechFallback: Bool {
        get { actions.state().isUsingSpeechFallback }
        set { actions.speech(newValue) }
    }
    private var rate: PlaybackRate {
        get { actions.state().rate }
        set { actions.rate(newValue) }
    }
    private var player: AVQueuePlayer? { queueSession.player }
    private var pendingSeek: PendingPlaybackSeek { seeking.pending }
    private var positionSeconds: TimeInterval {
        get { clock.positionSeconds }
        set { clock.update(positionSeconds: newValue) }
    }
    private var durationSeconds: TimeInterval { clock.durationSeconds }
    private var currentChapterIndex: Int {
        get { queueSession.currentChapterIndex }
        set { queueSession.selectChapter(newValue) }
    }

    /// A deliberate pause owns the current queue cursor. Reader controls use
    /// this to resume that cursor instead of treating the next Play tap as a
    /// new request from the reader's page anchor.
    func pause() {
        actions.autoplay(false)
        if pendingSeek.autoplay != nil { pendingSeek.autoplay = false }
        pendingSeek.chapter?.autoplay = false
        // Slice-2 speech-fallback route: when the synthesizer owns the
        // transport, pause/resume must drive it instead of the silent
        // AVQueuePlayer. We do NOT touch the MP3 player here — it stays
        // torn down until an MP3 takeover (`play(snapshot:)`) happens.
        if isUsingSpeechFallback {
            speechFallback.pause()
            isPlaying = false
            actions.paused(true)
            journeys.cancelPendingPlaybackJourney()
            return
        }
        player?.pause()
        isPlaying = false
        actions.paused(player != nil)
        journeys.cancelPendingPlaybackJourney()
        resumePersistence.persist(snapshot: snapshot, chapterIndex: currentChapterIndex,
            sourceChapterIndex: PlaybackResumeStore.sourceChapterIndex(snapshot: snapshot,
                playbackChapters: chapterSession.chapters, queueOffset: currentChapterIndex,
                segmentMode: isSegmentMode, segmentChapterIndex: segments.chapterIndex),
            positionSeconds: positionSeconds, isPlaying: isPlaying, force: true)
        actions.publish()
    }

    func resume() {
        if !navigation.hasAnchor { navigation.rememberReaderPlaybackAnchor() }
        if pendingSeek.autoplay != nil { pendingSeek.autoplay = true }
        if pendingSeek.chapter != nil {
            pendingSeek.chapter?.autoplay = true
            seeking.applyPending()
            return
        }
        if isUsingSpeechFallback {
            // Speech fallback already configured the audio session for
            // `.spokenAudio` when `playFallbackSpeech` ran — no extra
            // session work here. Resume just continues the utterance.
            speechFallback.resume()
            isPlaying = true
            actions.paused(false)
            return
        }
        journeys.beginPlaybackJourneyIfNeeded()
        guard let player else {
            actions.autoplay(true)
            if let snapshot, !snapshot.playableChapters.isEmpty {
                actions.play(snapshot, currentChapterIndex, true)
            }
            return
        }
        journeys.recordQueuedAudioIfNeeded()
        // Activate the audio session lazily, only when the user actually
        // starts playback (Play button, lock-screen control, widget toggle).
        // This is what claims the audio focus from Spotify / Apple Music /
        // etc. — doing it earlier (e.g. on book open) interrupts other
        // apps even though we never produce a sound.
        systemPlayback.ensureAudioSession()
        player.rate = rate.rawValue
        isPlaying = true
        actions.paused(false)
        actions.publish()
    }

    /// Engage the accessibility speech fallback for the given chapter
    /// text. `text` must be non-empty — empty input is treated as a
    /// no-op so the fallback flag never silently flips on a degenerate
    /// call. Configures the system audio session for `.spokenAudio`
    /// (via `SpeechFallbackPlayer`) and surfaces `isPlaying = true`
    /// so the existing transport UI (play/pause button, mini-player)
    /// reflects the correct state without further wiring.
    ///
    /// The MP3 path is NOT primed — callers that already loaded a
    /// snapshot keep it; calling `play(snapshot:)` later cleanly
    /// switches back to MP3 and stops the synthesizer in the same turn
    /// so the user never hears both transports.
    func playFallbackSpeech(text: String, languageCode: String? = nil) {
        guard !text.isEmpty else { return }
        speechFallback.speak(text: text, languageCode: languageCode)
        isUsingSpeechFallback = true
        isPlaying = true
    }
    func playOrFallback(
        snapshot: JobSnapshot?, chapterIndex: Int, chapterText: String?, languageCode: String? = nil
    ) -> SpeechPlaybackRoute.AttemptResult {
        switch SpeechPlaybackRoute.plan(snapshot: snapshot, chapterIndex: chapterIndex, chapterText: chapterText) {
        case .audio(let snapshot, let offset):
            actions.play(snapshot, offset, true)
            return .startedAudio
        case .speech(let text):
            playFallbackSpeech(text: text, languageCode: languageCode)
            return .startedSpeechFallback
        case .unavailable: return .noOp
        }
    }

    func navigateChapter(_ direction: PlaybackChapterQueue.ChapterNavigationDirection) {
        // Keep a waiting page seek and its Pause intent until the first file.
        if player == nil, pendingSeek.chapter != nil { return }
        if !isSegmentMode {
            seeking.cancel()
            if case .backward = direction, ProcessInfo.processInfo.arguments.contains("-readerNavigationDebug") {
                print("NAV previousChapter current=\(currentChapterIndex) position=\(positionSeconds) segmentMode=\(isSegmentMode)")
            }
        }
        let move = PlaybackChapterQueue.navigation(direction: direction, snapshot: snapshot,
            chapters: chapterSession.chapters, currentIndex: currentChapterIndex, position: positionSeconds,
            segmentMode: isSegmentMode, hasPlayer: player != nil)
        switch move {
        case .none: return
        case .segment(let index): seeking.navigateToSegmentChapter(index)
        case .seekStart: seeking.seek(to: 0)
        case .load(let index):
            if let snapshot { actions.play(snapshot, index, isPlaying) }
        case .reload(let index):
            if let snapshot {
                let wasPlaying = isPlaying
                actions.play(snapshot, index, false)
                if wasPlaying { resume() }
            }
        case .advance:
            // Reconcile via URL first — KVO may already have advanced the index
            // on fast devices; fall back to +1 only when nothing changed.
            let before = currentChapterIndex
            player?.advanceToNextItem()
            _ = queueSession.reconcileChapter(segmentMode: isSegmentMode, segments: segments, chapterURLs: actions.chapterURLs)
            if currentChapterIndex == before { currentChapterIndex += 1 }
            positionSeconds = 0
            actions.chapterChanged()
            actions.publish()
        }
    }

    func setRate(_ rate: PlaybackRate) {
        self.rate = rate
        if let player, isPlaying { player.rate = rate.rawValue }
        actions.publish()
    }

    /// Relative chapter navigation must resolve its target segment through the
    /// same seek path as the progress slider, including pending audio and intent.
    func skip(by deltaSeconds: TimeInterval) {
        guard deltaSeconds.isFinite else { return }
        if isSegmentMode {
            seeking.seek(to: max(0, positionSeconds + deltaSeconds))
            return
        }
        seeking.cancel()
        guard let target = queueSession.skip(by: deltaSeconds, duration: durationSeconds) else { return }
        positionSeconds = target
        broadcast.publishPosition(positionSeconds)
        actions.publish()
    }

    /// Advance to the next rate in `PlaybackRate.primaryRates`, wrapping
    /// from the last entry back to the first.
    func cycleRate() {
        let cases = PlaybackRate.primaryRates
        guard let idx = cases.firstIndex(of: rate) else {
            setRate(.x075)
            return
        }
        let next = cases[(idx + 1) % cases.count]
        setRate(next)
    }

    /// Skip forward by `seconds` (default 15 s). Clamped to [0, duration].
    func skipForward(seconds: Double? = nil) {
        skip(by: seconds ?? PlaybackSystemSession.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey))
    }

    /// Skip backward by `seconds` (default 15 s). Clamped to [0, duration].
    func skipBackward(seconds: Double? = nil) {
        let seconds = seconds ?? PlaybackSystemSession.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey)
        guard seconds > 0, positionSeconds <= seconds else {
            skip(by: -seconds)
            return
        }
        rewindToCurrentChapterStart()
    }

    func rewindToCurrentChapterStart() {
        seeking.cancel()
        guard player != nil else { return }
        guard queueSession.rewind(chapter: segments.chapterIndex, segmentMode: isSegmentMode,
                                  isPlaying: isPlaying, rate: rate) else { skip(by: -positionSeconds); return }
        if isSegmentMode { segments.setBase(0) }
        positionSeconds = 0
        broadcast.publishPosition(positionSeconds)
        actions.publish()
    }
    #if os(iOS)
    func handleInterruption(typeRaw: UInt?, optionRaw: UInt) {
        switch systemPlayback.interruptionAction(typeRaw: typeRaw, optionRaw: optionRaw, isPlaying: isPlaying) {
        case .pause:
            player?.pause()
            isPlaying = false
        case .resume:
            player?.rate = rate.rawValue
            isPlaying = player?.rate ?? 0 > 0
            actions.publish()
        case .none: break
        }
    }

    func handleRouteChange(reasonRaw: Int?) {
        guard let raw = reasonRaw,
              let reason = PlaybackSystemSession.RouteChangeReason(rawValue: raw) else { return }
        if PlaybackSystemSession.shouldPauseForRouteChange(reason: reason), isPlaying {
            player?.pause()
            isPlaying = false
            actions.publish()
        }
    }

    func handleMediaServicesReset() {
        guard systemPlayback.recoverMediaServices(isPlaying: isPlaying) else { return }
        player?.rate = rate.rawValue
        isPlaying = player?.rate ?? 0 > 0
        actions.publish()
    }
    #endif
    func mountStreamingQueue(_ queue: AVQueuePlayer, identity: SegmentBacklog.Identity) {
        _ = queueSession.activateSegment(identity, segments: segments)
        if let resume = actions.state().pendingResumePosition, resume > 0 {
            queue.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            positionSeconds = resume
            actions.clearResumePosition()
        }
        actions.observe()
        // Only auto-start the first segment if the user had already
        // expressed intent to play (e.g. tapped Play while waiting for
        // the conversion to produce the first chunk, or asked for
        // "From the beginning" / "Previous chapter" which arms
        // `actions.state().pendingAutoplay` via `prepareSegmentRestart`). Otherwise
        // we set everything up but stay paused — the next user tap
        // on Play / lock-screen / widget will call `resume()`.
        if isPlaying || actions.state().pendingAutoplay {
            actions.activate(queue)
        } else {
            queue.rate = 0
        }
        #if os(iOS)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        log.debug("[enqueueSegment] AVQueuePlayer created (isPlaying=\(self.isPlaying)). items=\(queue.items().count) rate=\(queue.rate) currentItemNil=\(queue.currentItem == nil)")
        actions.chapterChanged()
        actions.publish()
    }
}
