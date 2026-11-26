import Combine
import Foundation

/// The committed transport view shared by Apple playback consumers. Revision
/// orders publications within a player; generation identifies the queue owner.
struct PlaybackTransportState: Equatable {
    enum Source: Equatable {
        case none, chapterAudio, streamingAudio, speech
    }

    struct Content: Equatable {
        let generation: UUID
        let job: JobSnapshot?
        let source: Source
        let usesSegmentQueue: Bool
        let chapter: JobSnapshot.Chapter?
        let chapterIndex: Int
        let streamingChapterIndex: Int?
        let chapterTitle: String
        let sentenceID: String?
        let isPlaying: Bool
        let isSeeking: Bool
        let hasPendingAutoplay: Bool
        let isConverting: Bool
        let conversionProgress: Double?
        let firstChapterReady: Bool
        let firstSegmentReady: Bool
        let isChapterDurationEstimated: Bool
        let isPositionApproximate: Bool
        let navigation: AudioPlayer.PendingNavigation?
        let rate: PlaybackRate
        let lastRouteChange: AudioPlayer.RouteChangeReason?
        let coverArtData: Data?
        let lastError: PlaybackFailure?

        var isLoading: Bool { isSeeking || (!isPlaying && isConverting && !firstChapterReady) }
    }

    struct Sample: Equatable {
        let content: Content
        let clock: PlaybackClock.Snapshot

        var playbackPositionSeconds: TimeInterval {
            PlaybackChapterQueue.rateAdjustedDuration(seconds: clock.positionSeconds, rate: content.rate)
        }

        var playbackDurationSeconds: TimeInterval {
            PlaybackChapterQueue.rateAdjustedDuration(seconds: clock.durationSeconds, rate: content.rate)
        }
    }

    let revision: UInt64
    let sample: Sample
    var content: Content { sample.content }
    var clock: PlaybackClock.Snapshot { sample.clock }
    var playbackPositionSeconds: TimeInterval { sample.playbackPositionSeconds }
    var playbackDurationSeconds: TimeInterval { sample.playbackDurationSeconds }
}

@MainActor
final class PlaybackTransportPublication {
    private let subject: CurrentValueSubject<PlaybackTransportState, Never>
    private var pending: Task<Void, Never>?

    init(_ sample: PlaybackTransportState.Sample) {
        subject = CurrentValueSubject(.init(revision: 0, sample: sample))
    }

    var state: PlaybackTransportState { subject.value }
    var updates: AnyPublisher<PlaybackTransportState, Never> { subject.eraseToAnyPublisher() }

    /// Playback services perform multiple assignments in one main-actor turn.
    /// Reconcile after the turn, never inside a property's will-change event.
    func schedule(_ capture: @escaping @MainActor () -> PlaybackTransportState.Sample?) {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            guard let self else { return }
            self.pending = nil
            guard let sample = capture() else { return }
            let previous = self.subject.value
            guard previous.sample != sample else { return }
            self.subject.send(.init(revision: previous.revision + 1, sample: sample))
        }
    }
}

extension AudioPlayer {
    /// Event-driven presentation consumes the committed state. Commands still
    /// consult the live queue while performing a transport transaction.
    var transportState: PlaybackTransportState { transportPublisher().state }
    var transportUpdates: AnyPublisher<PlaybackTransportState, Never> { transportPublisher().updates }
    var transportContentUpdates: AnyPublisher<PlaybackTransportState.Content, Never> {
        transportUpdates.map(\.content).removeDuplicates().eraseToAnyPublisher()
    }

    func scheduleTransportPublication() {
        transportPublication?.schedule { [weak self] in self?.captureTransportSample() }
    }

    func handlePlaybackRouteChange(reasonRaw: Int?) {
        guard let reasonRaw, let reason = RouteChangeReason(rawValue: reasonRaw) else { return }
        playbackRouteChanged(reason)
        #if os(iOS)
        services.transport.handleRouteChange(reasonRaw: reasonRaw)
        #endif
    }

    /// Reads live facts at synchronous platform publication boundaries.
    func captureTransportSample() -> PlaybackTransportState.Sample {
        .init(content: transportContent, clock: playbackClock.snapshot)
    }

    private var transportContent: PlaybackTransportState.Content {
        let source: PlaybackTransportState.Source
        if isUsingSpeechFallback { source = .speech }
        else if !hasLoadedAudioQueue { source = .none }
        else { source = usesSegmentQueue ? .streamingAudio : .chapterAudio }
        return .init(generation: remotePlaybackGeneration, job: snapshot, source: source, usesSegmentQueue: usesSegmentQueue,
            chapter: currentPlaybackChapter, chapterIndex: currentChapterIndex,
            streamingChapterIndex: activeStreamingChapterIndex, chapterTitle: effectiveChapterTitle,
            sentenceID: activeSentenceId, isPlaying: isPlaying, isSeeking: isSeeking,
            hasPendingAutoplay: hasPendingAutoplay, isConverting: isConverting, conversionProgress: conversionProgress,
            firstChapterReady: firstChapterReady, firstSegmentReady: firstSegmentReady,
            isChapterDurationEstimated: isChapterDurationEstimated, isPositionApproximate: isPositionApproximate,
            navigation: pendingNavigation, rate: rate, lastRouteChange: lastRouteChange, coverArtData: coverArtData,
            lastError: lastError)
    }
}
