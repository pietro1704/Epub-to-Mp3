import AVFoundation
import Foundation
import os.log
#if canImport(UIKit)
import UIKit
#endif

/// Owns chapter-queue installation, snapshot reconciliation and full-file
/// handoff. Only AudioPlayer grants transport intent and invalidates generation.
@MainActor
final class PlaybackChapterExecution {
    struct State {
        let snapshot: JobSnapshot?
        let segmentMode: Bool
        let isPlaying: Bool
        let pendingAutoplay: Bool
        static let empty = State(snapshot: nil, segmentMode: false, isPlaying: false, pendingAutoplay: false)
    }
    struct Actions {
        let state: () -> State
        let snapshotChanged: (JobSnapshot) -> Void
        let fullChapterMode: () -> Void
        let playingChanged: (Bool) -> Void
        let seeking: (Bool) -> Void
        let cancelAutoplay: () -> Void
        let teardown: () -> Void
        let observe: () -> Void
        let activate: (AVQueuePlayer) -> Void
        let install: (JobSnapshot, Int, Bool) -> Void
        let resume: () -> Void
        let publish: () -> Void
        let chapterInstalled: () -> Void
        let failed: (PlaybackFailure) -> Void
        let resolveURL: (String?, String, Int) -> URL?
    }
    private let queueSession: PlaybackQueueSession
    private let segments: PlaybackSegmentSession
    private let chapterSession: PlaybackChapterSession
    private let resumePersistence: PlaybackResumeStore
    private let readiness: PlaybackConversionReadiness
    private let seeking: PlaybackSeekExecution
    private let journeys: PlaybackJourneyRecorder
    private let clock: PlaybackClock
    private let actions: Actions
    private let log = Logger(subsystem: "epub2mp3", category: "AudioPlayer")
    init(queue: PlaybackQueueSession, segments: PlaybackSegmentSession, chapters: PlaybackChapterSession,
         resume: PlaybackResumeStore, readiness: PlaybackConversionReadiness, seeking: PlaybackSeekExecution,
         journeys: PlaybackJourneyRecorder, clock: PlaybackClock, actions: Actions) {
        queueSession = queue
        self.segments = segments
        chapterSession = chapters
        resumePersistence = resume
        self.readiness = readiness
        self.seeking = seeking
        self.journeys = journeys
        self.clock = clock
        self.actions = actions
    }
    private var snapshot: JobSnapshot? { actions.state().snapshot }
    private var isSegmentMode: Bool { actions.state().segmentMode }
    private var isPlaying: Bool { actions.state().isPlaying }
    private var pendingAutoPlay: Bool { actions.state().pendingAutoplay }
    private var player: AVQueuePlayer? { queueSession.player }
    private var pendingSeek: PendingPlaybackSeek { seeking.pending }
    private var currentChapterIndex: Int {
        get { queueSession.currentChapterIndex }
        set { queueSession.selectChapter(newValue) }
    }
    private var positionSeconds: TimeInterval { clock.positionSeconds }

    /// Build the AVQueuePlayer for `snapshot` starting at `chapterIndex`, but
    /// **do not** start playback. Audio only begins after an explicit user
    /// action: tapping the Play button, the lock-screen play control, or the
    /// widget toggle (all of which route through `actions.resume()` /
    /// `togglePlayPause()`).
    ///
    /// Historical note: this method used to call `queue.play()` and set
    /// `isPlaying = true`, which meant every view-appear path (reader open,
    /// player sheet, instant reader) silently kicked off audio. That violated
    /// the principle that media should never auto-start without user intent.
    func play(snapshot: JobSnapshot, startingAt chapterIndex: Int, restoreAutoplay: Bool) {
        // Audio session is intentionally NOT activated here — `setActive(true)`
        // on a `.playback` / `.longFormAudio` session interrupts other apps
        // (Spotify, Apple Music, podcast apps) even when our queue is paused.
        // We defer activation to `actions.resume()` so silence on the user's side
        // never costs them their currently-playing audio.
        log.debug("[load] snapshot jobId=\(snapshot.jobId) chapterIndex=\(chapterIndex) playableChapters=\(snapshot.playableChapters.count)")
        // Touch last-access so LRU eviction knows this audiobook was opened.
        AudiobookCacheEviction.touchLastAccess(jobId: snapshot.jobId)
        // Embedded-runtime preservation: when the host already streamed
        // segments into the queue via `enqueueSegment` (the only way
        // audio reaches the player in embedded mode — chapters carry
        // no `downloadUrl`), a subsequent `play(snapshot:)` call from
        // the divergence-dialog path used to teardown the live player
        // and then refuse to rebuild (no URLs). The user saw "asks to
        // download, never plays" even though every chapter was on disk
        // and queued. Keep the live segment queue intact; the caller
        // (`startFromBeginning` / `startFromReaderPage`) will issue the
        // appropriate `seek` + `resume` after this returns.
        if isSegmentMode, player != nil, snapshot.playableChapters.isEmpty {
            actions.snapshotChanged(snapshot)
            actions.publish()
            return
        }
        let wasPlaying = isPlaying
        if let marker = PlaybackResumeStore.markerBeforeTeardown(
            jobId: self.snapshot?.jobId,
            chapterIndex: currentChapterIndex,
            positionSeconds: positionSeconds
        ) {
            resumePersistence.saveBeforeTeardown(marker)
        }
        actions.teardown()
        // Reset index immediately after teardown so subscribers never see
        // the old chapter index in the window before the new one is set below.
        currentChapterIndex = max(0, min(chapterIndex, snapshot.playableChapters.count - 1))
        actions.fullChapterMode()
        segments.resetCursor()
        queueSession.selectSentence(nil)
        chapterSession.clear()
        actions.snapshotChanged(snapshot)

        guard let queue = chapterSession.install(snapshot: snapshot, startingAt: chapterIndex,
            queueSession: queueSession, resolveURL: { self.actions.resolveURL($0, $1, $2) }) else {
            if snapshot.playableChapters.isEmpty {
                log.warning("[load] no playable chapters — player not started")
                if snapshot.isTerminal { actions.failed(.noPlayableChapters) }
            }
            return
        }

        actions.observe()

        // Restore prior position for this chapter, if any.
        let resumeMarker = resumePersistence.marker(jobId: snapshot.jobId, chapterIndex: currentChapterIndex)
        if let marker = resumeMarker,
           marker.positionSeconds > 1.0 {
            queue.seek(to: CMTime(seconds: marker.positionSeconds, preferredTimescale: 600))
        }

        // Queue is paused at rate 0 (default). Lock-screen / widget / in-app
        // play controls call `actions.resume()` to start playback.
        queue.rate = 0
        actions.playingChanged(false)
        // If the previous snapshot was already playing (e.g. user jumped to a
        // new chapter while listening), or the user tapped Play while waiting
        // for the first streamed MP3 URL, preserve that intent.
        if wasPlaying || pendingAutoPlay || (restoreAutoplay && resumeMarker?.wasPlaying == true) {
            actions.activate(queue)
        }
        // Re-register for remote-control events so the lock-screen play
        // button works even when we never auto-started. Idempotent.
        #if os(iOS)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        actions.chapterInstalled()
        actions.publish()
    }

    /// Live-update the snapshot. Used by the native reader's SSE
    /// subscription so newly-finished chapters can be appended to the
    /// AVQueuePlayer without interrupting the chapter currently playing.
    ///
    /// Two kinds of change are applied:
    ///  - **Append** newly-finished chapters at the tail (the common case).
    ///  - **Replace** an already-queued chapter whose `downloadUrl` changed
    ///    (a re-synthesis / retry that produced a new file at the same index).
    ///    Only chapters strictly ahead of the one currently playing are
    ///    swapped, so the playhead is never disturbed.
    func updateSnapshot(_ newSnapshot: JobSnapshot) {
        if let pending = pendingSeek.chapter, pending.jobID != newSnapshot.jobId { seeking.cancel() }
        let previousSnapshot = snapshot
        actions.snapshotChanged(newSnapshot)
        switch chapterSession.updatePlan(snapshot: newSnapshot, hasPlayer: player != nil,
            segmentMode: isSegmentMode, currentChapterIndex: currentChapterIndex, pendingSeek: pendingSeek) {
        case .waiting: return
        case .finishPendingSeek: finishStreaming(snapshot: newSnapshot)
        case .initialQueue(let start, let pendingReaderPage):
            actions.install(newSnapshot, start, false)
            // Restore ownership synchronously before queued duration observers
            // can consume a page seek from another book or chapter.
            if let pendingReaderPage, player != nil,
               pendingReaderPage.jobID == newSnapshot.jobId,
               pendingReaderPage.jobID == snapshot?.jobId,
               pendingReaderPage.forChapterIndex == currentChapterIndex {
                pendingSeek.proportional = pendingReaderPage
                seeking.applyPendingProportionalSeek()
            }
        case .segmentQueue:
            seeking.applyPending()
            actions.publish()
        case .reconcileQueue:
            guard let player else { return }
            chapterSession.reconcile(previousSnapshot: previousSnapshot, newSnapshot: newSnapshot,
                currentChapterIndex: currentChapterIndex, queue: player, queueSession: queueSession,
                resolveURL: { self.actions.resolveURL($0, $1, $2) })
            seeking.applyPending()
            actions.publish()
        }
    }

    /// Publish a completed manifest for a segment-streaming session without
    /// leaving playback tied to temporary MP3 files. The final chapter URLs
    /// restore standard seeking, resume, and offline playback.
    func finishStreaming(snapshot: JobSnapshot) {
        switch pendingSeek.fullFileHandoff(snapshot: snapshot, segmentMode: isSegmentMode) {
        case .unrelated: break
        case .waiting(let terminal):
            actions.snapshotChanged(snapshot)
            if terminal {
                seeking.cancel()
                actions.failed(.noPlayableChapters)
            }
            return
        case .ready(let target, let request):
            // A transport handoff is not a user cancellation. Carry the
            // original journey and intent across teardown into the full file.
            let journeyID = journeys.suspendSeek()
            pendingSeek.chapter = nil
            actions.cancelAutoplay()
            actions.playingChanged(false)
            actions.install(snapshot, target, false)
            journeys.restoreSeek(journeyID)
            pendingSeek.chapter = request
            actions.seeking(true)
            readiness.isConverting = !snapshot.isTerminal
            seeking.applyPending()
            return
        }
        guard isSegmentMode, player != nil else {
            readiness.isConverting = false
            updateSnapshot(snapshot)
            return
        }
        let activeChapterID = PlaybackSegmentSession.chapterProgressEntry(
            forSegmentIndex: currentChapterIndex,
            chapterProgress: snapshot.chapterProgress ?? []
        )?.index
        // `positionSeconds` is chapter-relative in segment mode. The periodic
        // observer has already added `segments.cumulativeBase`, so subtracting
        // it here rewound the full-file handoff to an earlier segment.
        let activePosition = max(0, positionSeconds)
        let wasPlaying = isPlaying
        let target = activeChapterID.flatMap { chapterID in
            snapshot.playableChapters.firstIndex { $0.index == chapterID }
        } ?? 0
        readiness.isConverting = false
        // Once every full chapter file exists, replace the segment queue with
        // the canonical chapter queue. This restores normal previous/next,
        // seeking, resume markers, and offline playback semantics without
        // leaving the player permanently tied to per-segment items.
        actions.install(snapshot, target, false)
        if activePosition > 0 { seeking.seek(to: activePosition) }
        if wasPlaying { actions.resume() }
    }

}
