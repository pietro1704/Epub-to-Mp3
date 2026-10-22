import AVFoundation
import Foundation
import os.log

/// Segment-streaming ingestion point. Legacy local-stream oracle only;
/// production audio arrives from the backend artifact stream.
/// each TTS chunk closes, before the full chapter MP3 is written.
///
/// - Parameters:
///   - data: Raw MP3 bytes for this segment (Edge emits ID3-less MP3
///     frames; raw-byte append is valid — same trick as the sidecar).
///   - chapterIndex: Zero-based chapter index this segment belongs to.
///   - segmentIndex: Zero-based segment index within the chapter.
///
/// Behaviour:
/// 1. Writes `data` to a collision-safe temp file so `AVPlayerItem` can
///    reference a stable URL (AVFoundation requires file-backed URLs
///    for local MP3; it does not accept in-memory `Data`).
/// 2. Creates an `AVPlayerItem` and inserts it at the end of the queue.
/// 3. If this is the first segment ever, creates a paused queue and sets
///    `firstSegmentReady = true`. It starts only after explicit user
///    playback intent has been recorded.
///
/// Thread-safety: must be called on the main actor (same as all other
/// AudioPlayer methods).
@MainActor
final class PlaybackStreamAdmission {
    struct Actions {
        let prepare: () -> Void
        let isCurrent: (UUID) -> Bool
        let accepting: () -> Void
        let created: (AVQueuePlayer, SegmentBacklog.Identity) -> Void
        let ready: () -> Void
        let failed: (PlaybackFailure) -> Void
    }
    private let segments: PlaybackSegmentSession
    private let persistence: PlaybackSegmentPersistence
    private let queue: PlaybackQueueSession
    private let readiness: PlaybackConversionReadiness
    private let journeys: PlaybackJourneyRecorder
    private let actions: Actions
    private let log = Logger(subsystem: "epub2mp3", category: "AudioPlayer")
    init(segments: PlaybackSegmentSession, persistence: PlaybackSegmentPersistence,
         queue: PlaybackQueueSession, readiness: PlaybackConversionReadiness,
         journeys: PlaybackJourneyRecorder, actions: Actions) {
        self.segments = segments
        self.persistence = persistence
        self.queue = queue
        self.readiness = readiness
        self.journeys = journeys
        self.actions = actions
    }

    func enqueueAsync(data: Data, identity: SegmentBacklog.Identity, generation: UUID,
                      sentenceID: String?, publication: LatencyObservation.StreamPublication?,
                      receipt: LatencyObservation.StreamRequestReceipt?, maximumDeferredSegments: Int) async -> Bool {
        await persistence.enqueue(data: data, identity: identity,
            validate: { [weak self] in
                guard let self, self.actions.isCurrent(generation) else { return .invalid }
                return self.segments.files[identity] == nil ? .current : .duplicate
            }, prepare: { [weak self] in
                guard let self, self.prepare(data: data, identity: identity) else { return false }
                return await self.segments.waitForCapacity(maximumCount: maximumDeferredSegments)
            }, failed: { [weak self] in self?.actions.failed(.segmentWriteFailed) },
            accept: { [weak self] file in
                self?.accept(file, identity: identity, byteCount: data.count,
                             sentenceID: sentenceID, publication: publication, receipt: receipt)
            })
    }

    func enqueue(data: Data, identity: SegmentBacklog.Identity, sentenceID: String?,
                 publication: LatencyObservation.StreamPublication?, receipt: LatencyObservation.StreamRequestReceipt?) {
        guard prepare(data: data, identity: identity) else { return }
        let file: URL
        do {
            file = try persistence.writeSynchronously(data, identity: identity)
        } catch {
            actions.failed(.segmentWriteFailed)
            return
        }
        accept(file, identity: identity, byteCount: data.count,
               sentenceID: sentenceID, publication: publication, receipt: receipt)
    }

    private func prepare(data: Data, identity: SegmentBacklog.Identity) -> Bool {
        actions.prepare()
        switch segments.prepare(data: data, identity: identity, hasPlayer: queue.player != nil) {
        case .accepted: return true
        case .ignored: return false
        case .emptyFailure:
            actions.failed(.emptySegmentData)
            return false
        }
    }

    private func accept(_ file: URL, identity: SegmentBacklog.Identity, byteCount: Int,
                        sentenceID: String?, publication: LatencyObservation.StreamPublication?,
                        receipt: LatencyObservation.StreamRequestReceipt?) {
        actions.accepting()
        switch segments.admit(file, identity: identity, sentenceID: sentenceID,
                              publication: publication, receipt: receipt, queueSession: queue) {
        case .created(let player): actions.created(player, identity)
        case .duplicate:
            persistence.remove(file)
            log.notice("[enqueueSegment] duplicate backlog entry ignored ch=\(identity.chapterIndex) seg=\(identity.segmentIndex)")
            return
        case .buffered(let player, let highWaterMark):
            if highWaterMark {
                log.notice("[enqueueSegment] deferred audio reached \(SegmentBacklog.advisoryHighWaterMark) segments; preserving file-backed backlog until playback drains it")
                readiness.status.record(.info, "Playback is buffering ahead; audio remains queued until it can play.")
            }
            queue.drainSegments(segments)
            log.debug("[enqueueSegment] deferred ch=\(identity.chapterIndex) seg=\(identity.segmentIndex), pending=\(self.segments.deferredCount), queue=\(player.items().count)")
        }
        readiness.markFirstSegmentReady()
        journeys.recordQueuedAudioIfNeeded()
        readiness.status.record(.chunkComplete,
            "ch\(identity.chapterIndex) segment \(identity.segmentIndex) ready (\(byteCount) bytes)")
        actions.ready()
    }
    /// Only the first unbuffered segment carrying explicit Play/Seek intent
    /// may attach a diagnostic journey; prefetch never inherits consent.
    /// Only the first available segment of an explicitly requested, unbuffered
    /// chapter can carry consent. The manifest owner requests segments in order;
    /// sparse/resumed manifests need not start at zero. Prefetch has no journey.
    func authorization(jobID: String, chapterIndex: Int, segmentIndex: Int,
                       snapshot: JobSnapshot, pendingChapter: PendingPlaybackSeek.ChapterRequest?,
                       hasPlayer: Bool, pendingAutoplay: Bool,
                       session: StreamingDiagnosticsSession) -> StreamingDiagnosticsSession.Authorization? {
        guard snapshot.jobId == jobID, segmentIndex >= 0 else { return nil }
        let chapter = chapterIndex - PlaybackSegmentSession.segmentManifestIndexOffset(snapshot)
        guard chapter >= 0,
              !segments.files.keys.contains(where: { $0.chapterIndex == chapter }) else { return nil }
        if let pending = pendingChapter, let journeyID = journeys.seekID {
            guard pending.jobID == jobID, pending.chapterIndex == chapter else { return nil }
            return session.authorization(for: journeyID)
        }
        // The manifest owner calls this immediately before downloading its
        // next available candidate. A queue offset is not a chapter identity:
        // subset conversions or empty earlier manifests may begin much later.
        guard !hasPlayer, pendingAutoplay, let journeyID = journeys.playbackID,
              let candidate = snapshot.chapterProgress?.first(where: { $0.index == chapterIndex }),
              candidate.isCompleted || candidate.status?.lowercased() == "processing" else { return nil }
        return session.authorization(for: journeyID)
    }
}
