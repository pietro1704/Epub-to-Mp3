import AVFoundation
import Foundation

/// Builds and retains the concrete playback seams. The weak authority owns
/// published intent/generation; this graph contains no playback algorithms.
@MainActor
final class PlaybackServices {
    struct Configuration {
        let resumeStore: ResumeStore
        let speech: SpeechFallbackPlayer?
        let clock: PlaybackClock
        let artifacts: LocalAudioArtifactStore?
        let writer: SegmentFileWriter?
    }
    private weak var authority: AudioPlayer?
    let clock: PlaybackClock
    let queue: PlaybackQueueSession
    let persistence: PlaybackSegmentPersistence
    let resume: PlaybackResumeStore
    let speech: SpeechFallbackPlayer
    let broadcast = PlaybackBroadcast()
    let readiness = PlaybackConversionReadiness()
    let reader = ReaderPlaybackSeek()
    let chapters = PlaybackChapterSession()
    let navigation = ChapterNavigationDecision()
    let segments = PlaybackSegmentSession()
    let journeys = PlaybackJourneyRecorder()
    let publication = NowPlayingPublication()
    let bookProgress = PlaybackBookProgress()
    let sleep: SleepPlaybackTimer

    init(authority: AudioPlayer, configuration: Configuration) {
        self.authority = authority
        clock = configuration.clock
        queue = PlaybackQueueSession(clock: configuration.clock)
        persistence = PlaybackSegmentPersistence(writer: configuration.writer ?? SegmentFileWriter())
        resume = PlaybackResumeStore(store: configuration.resumeStore, artifactStore: configuration.artifacts)
        speech = configuration.speech ?? SpeechFallbackPlayer()
        sleep = SleepPlaybackTimer(clock: configuration.clock)
    }

    lazy var system: PlaybackSystemSession = PlaybackSystemSession(actions: .init(
        play: { [weak authority] in authority?.resume() },
        pause: { [weak authority] in authority?.pause() },
        toggle: { [weak authority] in authority?.togglePlayPause() },
        next: { [weak authority] in authority?.nextChapter() },
        previous: { [weak authority] in authority?.previousChapter() },
        seek: { [weak authority] in authority?.seek(to: $0) },
        skip: { [weak authority] in authority?.skip(by: $0) },
        setRate: { [weak authority] in authority?.setRate($0) },
        interruption: { [weak self] type, options in
            #if os(iOS)
            self?.transport.handleInterruption(typeRaw: type, optionRaw: options)
            #endif
        }, routeChange: { [weak self] reason in
            #if os(iOS)
            self?.transport.handleRouteChange(reasonRaw: reason)
            #endif
        }, mediaServicesReset: { [weak self] in
            #if os(iOS)
            self?.transport.handleMediaServicesReset()
            #endif
        }))

    lazy var seeking: PlaybackSeekExecution = PlaybackSeekExecution(
        queue: queue, segments: segments, chapters: chapters, reader: reader,
        navigation: navigation, journeys: journeys, clock: clock, broadcast: broadcast,
        navigationChanged: { [weak authority] in authority?.playbackNavigationChanged($0) },
        actions: .init(snapshot: { [weak authority] in authority?.snapshot },
            segmentMode: { [weak authority] in authority?.usesSegmentQueue ?? false },
            isPlaying: { [weak authority] in authority?.isPlaying ?? false },
            seeking: { [weak authority] in authority?.playbackSeekingChanged($0) },
            pauseTransport: { [weak authority] in authority?.pauseQueueForSeek() },
            cancelAutoplay: { [weak authority] in authority?.playbackAutoplayChanged(false) },
            play: { [weak authority] in authority?.play(snapshot: $0, startingAt: $1) },
            resume: { [weak authority] in authority?.resume() },
            publish: { [weak self] in self?.observation.updateNowPlayingInfo() },
            chapterChanged: { [weak self] in self?.observation.publishCurrentChapter(auto: false) },
            attachPublication: { [weak self] in self?.observation.attachCurrentStreamPublication(to: $0) },
            resolveURL: { [weak self] in self?.resolveURL($0, job: $1, chapter: $2) },
            chapterURLs: { [weak self] in self?.observation.playbackChapterURLs }))

    lazy var observation: PlaybackObservation = PlaybackObservation(
        queue: queue, segments: segments, chapters: chapters, seeking: seeking,
        navigation: navigation, journeys: journeys, resume: resume, clock: clock,
        broadcast: broadcast, publication: publication, sleepTimer: sleep, actions: .init(
            state: { [weak authority] in
                guard let authority else { return .empty }
                return .init(snapshot: authority.snapshot, isPlaying: authority.isPlaying, isSeeking: authority.isSeeking,
                             segmentMode: authority.usesSegmentQueue, rate: authority.rate, coverArtData: authority.coverArtData)
            }, playing: { [weak authority] in authority?.playbackPlayingChanged($0) },
            paused: { [weak authority] in authority?.playbackPauseOwnershipChanged($0) },
            streamingChapter: { [weak authority] in authority?.playbackStreamingChapterChanged($0) },
            structuralChange: { [weak authority] in authority?.objectWillChange.send() },
            pause: { [weak authority] in authority?.pause() },
            resolveURL: { [weak self] in self?.resolveURL($0, job: $1, chapter: $2) }))

    lazy var lifecycle: PlaybackSessionLifecycle = PlaybackSessionLifecycle(
        queue: queue, segments: segments, persistence: persistence, resume: resume,
        seeking: seeking, chapters: chapters, readiness: readiness, navigation: navigation,
        journeys: journeys, speech: speech, clock: clock, actions: .init(
            state: { [weak authority] in
                guard let authority else { return .empty }
                return .init(snapshot: authority.snapshot, isPlaying: authority.isPlaying, usesSpeech: authority.isUsingSpeechFallback)
            }, invalidateGeneration: { [weak authority] in authority?.invalidatePlaybackGeneration() },
            segmentMode: { [weak authority] in authority?.playbackSegmentModeChanged($0) },
            autoplay: { [weak authority] in authority?.playbackAutoplayChanged($0) },
            resumePosition: { [weak authority] in authority?.playbackResumePositionChanged($0) },
            paused: { [weak authority] in authority?.playbackPauseOwnershipChanged($0) },
            playing: { [weak authority] in authority?.playbackPlayingChanged($0) },
            seeking: { [weak authority] in authority?.playbackSeekingChanged($0) },
            speech: { [weak authority] in authority?.playbackSpeechChanged($0) },
            snapshotChanged: { [weak authority] in authority?.playbackSnapshotChanged($0) },
            backendChanged: { [weak authority] in authority?.backendBaseURL = $0 },
            failed: { [weak authority] in authority?.playbackFailureChanged($0) },
            publish: { [weak self] in self?.observation.updateNowPlayingInfo() }))

    lazy var transport: PlaybackTransportCommands = PlaybackTransportCommands(
        queue: queue, segments: segments, chapters: chapters, seeking: seeking,
        system: system, speech: speech, navigation: navigation, journeys: journeys,
        resume: resume, clock: clock, broadcast: broadcast, actions: .init(
            state: { [weak authority] in
                guard let authority else { return .empty }
                return .init(snapshot: authority.snapshot, isPlaying: authority.isPlaying, isSegmentMode: authority.usesSegmentQueue,
                             isUsingSpeechFallback: authority.isUsingSpeechFallback, rate: authority.rate,
                             pendingAutoplay: authority.hasPendingAutoplay, pendingResumePosition: authority.pendingPlaybackResumePosition)
            }, autoplay: { [weak authority] in authority?.playbackAutoplayChanged($0) },
            playing: { [weak authority] in authority?.playbackPlayingChanged($0) },
            paused: { [weak authority] in authority?.playbackPauseOwnershipChanged($0) },
            speech: { [weak authority] in authority?.playbackSpeechChanged($0) },
            rate: { [weak authority] in authority?.playbackRateChanged($0) },
            play: { [weak authority] in authority?.play(snapshot: $0, startingAt: $1, restoreAutoplay: $2) },
            publish: { [weak self] in self?.observation.updateNowPlayingInfo() },
            chapterChanged: { [weak self] in self?.observation.publishCurrentChapter() },
            observe: { [weak self] in self?.observation.attachObservers() },
            activate: { [weak authority] in authority?.activateQueue($0) },
            clearResumePosition: { [weak authority] in authority?.playbackResumePositionChanged(nil) },
            chapterURLs: { [weak self] in self?.observation.playbackChapterURLs }))

    lazy var chapter: PlaybackChapterExecution = PlaybackChapterExecution(
        queue: queue, segments: segments, chapters: chapters, resume: resume,
        readiness: readiness, seeking: seeking, journeys: journeys, clock: clock,
        actions: .init(state: { [weak authority] in
            guard let authority else { return .empty }
            return .init(snapshot: authority.snapshot, segmentMode: authority.usesSegmentQueue,
                         isPlaying: authority.isPlaying, pendingAutoplay: authority.hasPendingAutoplay)
        }, snapshotChanged: { [weak authority] in authority?.playbackSnapshotChanged($0) },
            fullChapterMode: { [weak authority] in authority?.playbackSegmentModeChanged(false) },
            playingChanged: { [weak authority] in authority?.playbackPlayingChanged($0) },
            seeking: { [weak authority] in authority?.playbackSeekingChanged($0) },
            cancelAutoplay: { [weak authority] in authority?.playbackAutoplayChanged(false) },
            teardown: { [weak self] in self?.lifecycle.teardown() },
            observe: { [weak self] in self?.observation.attachObservers() },
            activate: { [weak authority] in authority?.activateQueue($0) },
            install: { [weak authority] in authority?.play(snapshot: $0, startingAt: $1, restoreAutoplay: $2) },
            resume: { [weak authority] in authority?.resume() },
            publish: { [weak self] in self?.observation.updateNowPlayingInfo() },
            chapterInstalled: { [weak self] in self?.observation.publishCurrentChapter() },
            failed: { [weak authority] in authority?.playbackFailureChanged($0) },
            resolveURL: { [weak self] in self?.resolveURL($0, job: $1, chapter: $2) }))

    lazy var stream: PlaybackStreamAdmission = PlaybackStreamAdmission(
        segments: segments, persistence: persistence, queue: queue,
        readiness: readiness, journeys: journeys, actions: .init(
            prepare: { [weak authority] in authority?.prepareStreamAdmission() },
            isCurrent: { [weak authority] in authority?.remotePlaybackGeneration == $0 },
            accepting: { [weak authority] in authority?.playbackSegmentModeChanged(true) },
            created: { [weak self] in self?.transport.mountStreamingQueue($0, identity: $1) },
            ready: { [weak self] in self?.seeking.applyPending() },
            failed: { [weak authority] in authority?.playbackFailureChanged($0) }))

    private func resolveURL(_ path: String?, job: String?, chapter: Int?) -> URL? {
        PlaybackArtifactLocation.resolve(forDownloadPath: path, jobId: job, chapterIndex: chapter,
                                         backendBaseURL: authority?.backendBaseURL)
    }
}
