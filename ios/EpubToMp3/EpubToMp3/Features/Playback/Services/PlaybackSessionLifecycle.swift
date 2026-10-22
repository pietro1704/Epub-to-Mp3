import AVFoundation
import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/// Owns queue cancellation, retained-file release and preparation of the next
/// book session. Generation is invalidated by AudioPlayer before any teardown.
@MainActor
final class PlaybackSessionLifecycle {
    struct State {
        let snapshot: JobSnapshot?
        let isPlaying: Bool
        let usesSpeech: Bool
        static let empty = State(snapshot: nil, isPlaying: false, usesSpeech: false)
    }
    struct Actions {
        let state: () -> State
        let invalidateGeneration: () -> Void
        let segmentMode: (Bool) -> Void
        let autoplay: (Bool) -> Void
        let resumePosition: (TimeInterval?) -> Void
        let paused: (Bool) -> Void
        let playing: (Bool) -> Void
        let seeking: (Bool) -> Void
        let speech: (Bool) -> Void
        let snapshotChanged: (JobSnapshot?) -> Void
        let backendChanged: (URL) -> Void
        let failed: (PlaybackFailure?) -> Void
        let publish: () -> Void
    }
    private let queueSession: PlaybackQueueSession
    private let segments: PlaybackSegmentSession
    private let segmentPersistence: PlaybackSegmentPersistence
    private let resumePersistence: PlaybackResumeStore
    private let seeking: PlaybackSeekExecution
    private let chapterSession: PlaybackChapterSession
    private let readiness: PlaybackConversionReadiness
    private let navigation: ChapterNavigationDecision
    private let journeys: PlaybackJourneyRecorder
    private let speechFallback: SpeechFallbackPlayer
    private let clock: PlaybackClock
    private let actions: Actions
    init(queue: PlaybackQueueSession, segments: PlaybackSegmentSession, persistence: PlaybackSegmentPersistence,
         resume: PlaybackResumeStore, seeking: PlaybackSeekExecution, chapters: PlaybackChapterSession,
         readiness: PlaybackConversionReadiness, navigation: ChapterNavigationDecision,
         journeys: PlaybackJourneyRecorder, speech: SpeechFallbackPlayer, clock: PlaybackClock, actions: Actions) {
        queueSession = queue
        self.segments = segments
        segmentPersistence = persistence
        resumePersistence = resume
        self.seeking = seeking
        chapterSession = chapters
        self.readiness = readiness
        self.navigation = navigation
        self.journeys = journeys
        speechFallback = speech
        self.clock = clock
        self.actions = actions
    }
    private var snapshot: JobSnapshot? { actions.state().snapshot }
    private var isPlaying: Bool { actions.state().isPlaying }
    private var isUsingSpeechFallback: Bool { actions.state().usesSpeech }
    private var player: AVQueuePlayer? { queueSession.player }
    private var pendingSeek: PendingPlaybackSeek { seeking.pending }
    private var positionSeconds: TimeInterval {
        get { clock.positionSeconds }
        set { clock.update(positionSeconds: newValue) }
    }
    func beginRemoteStreaming(snapshot incomingSnapshot: JobSnapshot, backendBaseURL: URL) -> Bool {
        let isSameJob = snapshot?.jobId == incomingSnapshot.jobId
        guard isSameJob || (player == nil && !isPlaying && !isUsingSpeechFallback) else {
            return false
        }

        if !isSameJob {
            resumePersistence.resetRetention()
            actions.invalidateGeneration()
            readiness.reset(clearLatches: !isPlaying && player == nil)
            navigation.clearTitles()
            chapterSession.clear()
            queueSession.selectChapter(0)
            actions.segmentMode(false)
            segments.resetMetadata()
            queueSession.selectSentence(nil)
            chapterSession.awaitStart(0)
            actions.autoplay(false)
            actions.resumePosition(nil)
            actions.failed(nil)
        }

        actions.backendChanged(backendBaseURL)
        actions.snapshotChanged(incomingSnapshot)
        readiness.isConverting = !incomingSnapshot.isTerminal
        if let total = incomingSnapshot.chaptersTotal, total > 0 {
            readiness.conversionProgress = Double(incomingSnapshot.chaptersCompleted ?? 0) / Double(total)
        } else {
            readiness.conversionProgress = nil
        }
        actions.publish()
        return true
    }

    /// Tear down the player completely and clear the Now Playing widget.
    /// Call this when the reader session ends so the lock screen no
    /// longer shows stale metadata for a book that is no longer active.
    func stop() {
        navigation.clearAnchor()
        actions.autoplay(false)
        chapterSession.awaitStart(nil)
        // Speech-fallback teardown: when the synthesizer owns playback,
        // stop it and clear the flag BEFORE the MP3 teardown so a
        // subsequent `play(snapshot:)` tap drives the primary path
        // without first having to dismiss a phantom fallback transport.
        if isUsingSpeechFallback {
            speechFallback.stop()
            actions.speech(false)
        }
        teardown()
        actions.playing(false)
        actions.snapshotChanged(nil)
        chapterSession.clear()
        queueSession.selectChapter(0)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(iOS)
        UIApplication.shared.endReceivingRemoteControlEvents()
        #endif
    }

    func teardown() {
        pendingSeek.proportional = nil
        resumePersistence.resetRetention()
        actions.invalidateGeneration()
        segmentPersistence.cancelOperations()
        journeys.cancelPendingPlaybackJourney()
        seeking.cancel()
        pendingSeek.activeID = nil
        actions.seeking(false)
        segments.cancelWaiters()
        queueSession.teardown()
        actions.paused(false)
        queueSession.clearOwnership()
        // A segment is retained until it has been inserted into the queue or
        // this session ends. Teardown is the one intentional discard point:
        // no AVURLAsset from this player can still consume these files.
        segments.clearDeferred()
        segments.resetMetadata()
        queueSession.selectSentence(nil)
        // Remove segment temp files from the previous session. Best-effort:
        // if the OS already cleaned /tmp, the removeItem call is a no-op.
        segmentPersistence.removeDirectory()
    }

    /// Embedded-runtime restart hook. Teardown the live AVQueuePlayer
    /// and reset segment-mode bookkeeping so the host can rebuild the
    /// queue from disk-cache starting at an arbitrary chapter. Keeps
    /// `firstSegmentReady` true so the transport UI stays mounted
    /// during the rebuild — flipping it off would briefly swap the
    /// player bar for the play-menu and jump the layout.
    /// Arms `pendingAutoPlay` so the very next `enqueueSegment` starts
    /// playback immediately, matching the user's "from beginning" /
    /// "previous chapter" intent.
    func prepareSegmentRestart(resumePosition: TimeInterval? = nil) {
        teardown()
        actions.segmentMode(false)
        segments.resetCursor()
        queueSession.selectSentence(nil)
        actions.autoplay(true)
        actions.resumePosition(resumePosition)
        positionSeconds = 0
        actions.playing(false)
    }
}
