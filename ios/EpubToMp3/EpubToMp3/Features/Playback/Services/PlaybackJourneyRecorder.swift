import Foundation
import AVFoundation

/// Owns latency journey identities and one-shot milestones. Audible completion
/// is supplied by the real player clock; enqueued audio alone never finishes it.
@MainActor
final class PlaybackJourneyRecorder {
    /// A playback request is intentionally separate from audible output: a
    /// queue can be prepared or buffering long before it renders its first
    /// sample. The journey is completed only by the periodic player clock.
    private let store: LatencyObservationStore
    private(set) var playbackID: UUID?
    private(set) var seekID: UUID?
    private var hasRecordedQueuedAudio = false
    init(store: LatencyObservationStore = .shared) { self.store = store }

    func suspendSeek() -> UUID? {
        let value = seekID
        seekID = nil
        return value
    }
    func restoreSeek(_ value: UUID?) { seekID = value }
    func cancelSeek() {
        guard let journeyID = seekID else { return }
        _ = store.cancel(journeyID)
        seekID = nil
    }
    func beginPlaybackJourneyIfNeeded() {
        guard playbackID == nil else { return }
        let journeyID = store.beginProgressivePlayback()
        playbackID = journeyID
        hasRecordedQueuedAudio = false
    }

    func recordQueuedAudioIfNeeded() {
        guard let journeyID = playbackID, !hasRecordedQueuedAudio else { return }
        _ = store.record(.audioQueued, for: journeyID)
        hasRecordedQueuedAudio = true
    }

    func recordAudibleAudioIfNeeded(audible: Bool, attach: (UUID) -> Void) {
        guard let journeyID = playbackID,
              audible
        else {
            return
        }
        attach(journeyID)
        _ = store.record(.audioAudible, for: journeyID)
        store.finish(journeyID)
        playbackID = nil
        hasRecordedQueuedAudio = false
    }

    func cancelPendingPlaybackJourney() {
        guard let journeyID = playbackID else { return }
        _ = store.cancel(journeyID)
        playbackID = nil
        hasRecordedQueuedAudio = false
    }

    func beginSeekJourney() {
        cancelSeek()
        let journeyID = store.beginSeek()
        seekID = journeyID
    }

    func completeSeekJourney(attach: (UUID) -> Void) {
        guard let journeyID = seekID else { return }
        attach(journeyID)
        _ = store.record(.seekTargetReached, for: journeyID)
        store.finish(journeyID)
        seekID = nil
    }

    nonisolated static func hasAudibleOutput(
        timeControlStatus: AVPlayer.TimeControlStatus?,
        renderedSeconds: TimeInterval
    ) -> Bool {
        timeControlStatus == .playing && renderedSeconds > 0
    }
}
