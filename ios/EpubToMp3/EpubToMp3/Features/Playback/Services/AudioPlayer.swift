import Foundation
import AVFoundation
import Combine

/// Public command and publication authority for playback. Concrete services own
/// queue, seek, admission and lifecycle transactions; user intent stays here.
@MainActor
final class AudioPlayer: ObservableObject {

    nonisolated static let currentBookIDDefaultsKey = PlaybackResumeStore.currentBookIDDefaultsKey
    nonisolated static let currentChapterIndexDefaultsKey = PlaybackResumeStore.currentChapterIndexDefaultsKey
    static let readerCurrentChapterIndexDefaultsKey = ChapterNavigationDecision.readerCurrentChapterIndexDefaultsKey
    static let readerCurrentPageRatioDefaultsKey = ChapterNavigationDecision.readerCurrentPageRatioDefaultsKey
    static let readerCurrentSentenceIdDefaultsKey = ChapterNavigationDecision.readerCurrentSentenceIdDefaultsKey
    // MARK: Public observable state

    @Published private(set) var snapshot: JobSnapshot? {
        didSet {
            if oldValue?.jobId != snapshot?.jobId {
                invalidatePlaybackGeneration()
                if activeStreamingChapterIndex != nil { activeStreamingChapterIndex = nil }
                if oldValue != nil, coverArtData != nil { coverArtData = nil }
                playbackClock.audioOutput.snapshotChanged(to: snapshot?.jobId)
                playbackClock.update(positionSeconds: 0, durationSeconds: 0)
            }
            services.bookProgress.update(snapshot)
        }
    }

    var cachedBookChapterProgress: BookChapterProgress? { services.bookProgress.value }
    var currentChapterIndex: Int { services.queue.currentChapterIndex }
    var currentPlaybackChapter: JobSnapshot.Chapter? { services.observation.currentChapterValue }
    @Published private(set) var activeStreamingChapterIndex: Int?
    @Published private(set) var isPlaying: Bool = false
    private(set) var hasPausedPlaybackToResume = false

    func isPlaybackForReaderBook(_ bookID: String) -> Bool { services.navigation.isPlaybackForReaderBook(bookID) }

    /// Acknowledges the reader location for an explicit playback choice.
    func rememberReaderPlaybackAnchor() { services.navigation.rememberReaderPlaybackAnchor() }

    @Published private(set) var rate: PlaybackRate = .x100
    /// Transport-only updates live in PlaybackClock to avoid global redraws.
    var positionSeconds: TimeInterval { playbackClock.positionSeconds }
    var durationSeconds: TimeInterval { playbackClock.durationSeconds }
    var isChapterDurationEstimated: Bool {
        isSegmentMode && ChapterPlaybackTimeline(
            estimate: services.segments.estimatedDurations[services.segments.chapterIndex],
            confirmed: services.segments.confirmedEnd(for: services.segments.chapterIndex, snapshot: snapshot)
        ).isEstimated
    }
    var activeSentenceId: String? { services.queue.activeSentenceId }

    /// Cleared by the consumer after presenting the playback failure.
    @Published var lastError: PlayerError? {
        didSet {
            if let lastError { AppErrorReporter.message(lastError, context: "Playback") }
        }
    }

    typealias PlayerError = PlaybackFailure

    private var pendingSeek: PendingPlaybackSeek { services.seeking.pending }
    private var queueObservation: AnyCancellable?
    private var player: AVQueuePlayer? { services.queue.player }
    private var readinessObservation: AnyCancellable?
    var isConverting: Bool {
        get { services.readiness.isConverting }
        set { services.readiness.isConverting = newValue }
    }
    var conversionProgress: Double? {
        get { services.readiness.conversionProgress }
        set { services.readiness.conversionProgress = newValue }
    }
    var firstChapterReady: Bool { services.readiness.firstChapterReady }
    var firstSegmentReady: Bool { services.readiness.firstSegmentReady }
    var effectiveChapterTitle: String { services.observation.effectiveChapterTitle }

    @Published private(set) var isSeeking = false

    typealias PendingNavigation = PendingPlaybackSeek.PendingNavigation
    @Published private(set) var pendingNavigation: PendingNavigation?

    var isLoading: Bool { isSeeking || (!isPlaying && isConverting && !firstChapterReady) }

    @Published var coverArtData: Data?
    private var isUpdatingCoverArtData = false

    func updateCoverArtData(_ data: Data?) {
        guard !isUpdatingCoverArtData, coverArtData != data else { return }
        isUpdatingCoverArtData = true
        coverArtData = data
        isUpdatingCoverArtData = false
        updateNowPlayingInfo()
    }

    var sleepTimerRemaining: TimeInterval { playbackClock.sleepTimerRemaining }

    // MARK: AsyncStreams (positions + chapter changes)

    var currentChapter: AsyncStream<JobSnapshot.Chapter?> { services.broadcast.chapters(initial: services.observation.currentChapterValue) }
    var position: AsyncStream<TimeInterval> { services.broadcast.positions(initial: positionSeconds) }

    // MARK: Internals

    /// Mutable backend base URL for relative artifact paths.
    var backendBaseURL: URL?
    // Segment-mode cumulative position tracking: AVQueuePlayer reports
    // per-item position, but SyncEngine needs chapter-relative time.
    private var isSegmentMode = false { didSet { scheduleTransportPublication() } }
    /// Invalidates remote deliveries after stop or transport replacement, even
    /// when a newly opened session has the same backend job identifier.
    private(set) var remotePlaybackGeneration = UUID() { didSet { scheduleTransportPublication() } }
    var remoteSegmentGeneration: UUID? {
        player == nil || isSegmentMode ? remotePlaybackGeneration : nil
    }

    typealias RouteChangeReason = PlaybackSystemSession.RouteChangeReason
    private(set) var lastRouteChange: RouteChangeReason?
    private var transportObservers: Set<AnyCancellable> = []
    private(set) var transportPublication: PlaybackTransportPublication?

    func transportPublisher() -> PlaybackTransportPublication {
        if let transportPublication { return transportPublication }
        let publication = PlaybackTransportPublication(captureTransportSample())
        transportPublication = publication
        return publication
    }

    /// Shared only with transport surfaces, separate from structural publication.
    let playbackClock: PlaybackClock
    /// Published by the reader: true while it shows the narrated passage (see ReaderNarrationPairing).
    let readerPairing = ReaderNarrationPairing()
    /// Fires when the user moves the narration itself (seek, skip, chapter change, remote commands). The reader
    /// follows the narration again after it (READER-FOLLOW-NARRATION).
    let narrationJumps = PassthroughSubject<Void, Never>()

    @Published private(set) var isUsingSpeechFallback: Bool = false

    let location: ReaderLocation
    private let configuration: PlaybackServices.Configuration
    /// Concrete playback services. Internal so tests drive and inspect the real
    /// seams (`services.queue`, `services.segments`, …); production callers use
    /// the commands and publications of this type.
    private(set) lazy var services: PlaybackServices = PlaybackServices(authority: self, configuration: configuration)

    init(
        resumeStore: ResumeStore? = nil,
        location: ReaderLocation? = nil,
        backendBaseURL: URL? = nil,
        speechFallback: SpeechFallbackPlayer? = nil,
        playbackClock: PlaybackClock? = nil,
        artifactStore: LocalAudioArtifactStore? = nil,
        segmentFileWriter: SegmentFileWriter? = nil
    ) {
        let clock = playbackClock ?? PlaybackClock()
        self.playbackClock = clock
        // A custom marker backend may have no defaults domain. Its caller can
        // inject a location explicitly; otherwise retain the app channel.
        let location = location ?? ReaderLocation(defaults: resumeStore?.backingDefaults ?? .standard)
        self.location = location
        let markers = resumeStore ?? ResumeStore(storage: UserDefaultsResumeStorage(defaults: location.defaults))
        configuration = .init(location: location, resumeStore: markers, speech: speechFallback, clock: clock,
                              artifacts: artifactStore, writer: segmentFileWriter)
        self.backendBaseURL = backendBaseURL
        // Synchronous forwarding preserves old-value ordering and every assignment.
        readinessObservation = services.readiness.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        queueObservation = services.queue.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        objectWillChange.sink { [weak self] in self?.scheduleTransportPublication() }.store(in: &transportObservers)
        clock.$snapshot.dropFirst().sink { [weak self] _ in self?.scheduleTransportPublication() }.store(in: &transportObservers)
    }

    // The composition graph can only publish through these narrow authority
    // methods. It never stores another copy of intent or generation.
    var usesSegmentQueue: Bool { isSegmentMode }
    var hasPendingAutoplay: Bool { pendingAutoPlay }
    var pendingPlaybackResumePosition: TimeInterval? { pendingSegmentResumePosition }
    func playbackSnapshotChanged(_ value: JobSnapshot?) { snapshot = value }
    func playbackPlayingChanged(_ value: Bool) {
        if !value { playbackClock.audioOutput.clear() }
        isPlaying = value
    }
    func playbackSeekingChanged(_ value: Bool) {
        if value { playbackClock.audioOutput.clear() }
        isSeeking = value
    }
    func playbackRouteChanged(_ reason: RouteChangeReason) {
        lastRouteChange = reason
        scheduleTransportPublication()
    }
    func playbackPauseOwnershipChanged(_ value: Bool) { hasPausedPlaybackToResume = value }
    func playbackSpeechChanged(_ value: Bool) { isUsingSpeechFallback = value }
    func playbackRateChanged(_ value: PlaybackRate) { rate = value }
    func playbackSegmentModeChanged(_ value: Bool) { isSegmentMode = value }
    func playbackAutoplayChanged(_ value: Bool) { pendingAutoPlay = value }
    func playbackResumePositionChanged(_ value: TimeInterval?) { pendingSegmentResumePosition = value }
    func playbackFailureChanged(_ value: PlaybackFailure?) { lastError = value }
    func playbackStreamingChapterChanged(_ value: Int?) { activeStreamingChapterIndex = value }
    func invalidatePlaybackGeneration() { remotePlaybackGeneration = UUID() }
    func playbackNavigationChanged(_ value: PendingNavigation?) {
        guard pendingNavigation != value else { return }
        pendingNavigation = value
    }
    func pauseQueueForSeek() {
        player?.pause()
        isPlaying = false
    }
    func prepareStreamAdmission() {
        ensureRemoteCommands()
        if isPlaying { ensureAudioSession() }
    }

    // MARK: Remote commands (lazy — deferred to first playback)

    func ensureRemoteCommands() { services.system.ensureRemoteCommands() }

    // MARK: Audio session (lazy)

    private func ensureAudioSession() { services.system.ensureAudioSession() }

    // MARK: Public API

    func setSnapshot(_ snapshot: JobSnapshot) {
        if self.snapshot?.jobId != snapshot.jobId,
           hasLoadedAudioQueue || isPlaying || isUsingSpeechFallback || isSeeking || hasPendingAutoplay {
            stop()
        }
        self.snapshot = snapshot
        updateNowPlayingInfo()
    }

    /// Bind an active remote conversion before its first completed chapter
    /// exists. This gives progressive media chunks a stable player owner
    /// without interrupting another book that is already playing.
    @discardableResult
    func beginRemoteStreaming(snapshot incomingSnapshot: JobSnapshot, backendBaseURL: URL) -> Bool {
        return services.lifecycle.beginRemoteStreaming(snapshot: incomingSnapshot, backendBaseURL: backendBaseURL)
    }
    func setSegmentChapterEstimate(_ duration: TimeInterval, forChapterIndex chapterIndex: Int, startingRatio: Double = 0) {
        services.observation.setSegmentChapterEstimate(duration, forChapterIndex: chapterIndex, startingRatio: startingRatio)
    }

    func play(snapshot: JobSnapshot, startingAt chapterIndex: Int = 0, restoreAutoplay: Bool = true) {
        ensureRemoteCommands()
        if self.snapshot?.jobId != snapshot.jobId { services.navigation.clearAnchor() }
        hasPausedPlaybackToResume = false
        if isUsingSpeechFallback {
            services.speech.stop()
            isUsingSpeechFallback = false
        }
        services.chapter.play(snapshot: snapshot, startingAt: chapterIndex, restoreAutoplay: restoreAutoplay)
    }

    nonisolated static func restoredPlayableChapterOffset(snapshot: JobSnapshot, persistedEpubChapterIndex: Int) -> Int{ PlaybackChapterQueue.restoredPlayableChapterOffset(snapshot: snapshot, persistedEpubChapterIndex: persistedEpubChapterIndex) }

    func updateSnapshot(_ snapshot: JobSnapshot) {
        guard self.snapshot == nil || self.snapshot?.jobId == snapshot.jobId else { return }
        services.chapter.updateSnapshot(snapshot)
    }

    func finishStreaming(snapshot: JobSnapshot) {
        guard self.snapshot?.jobId == snapshot.jobId else { return }
        services.chapter.finishStreaming(snapshot: snapshot)
    }
    func pause() {
        services.transport.pause()
    }
    func resume() {
        services.transport.resume()
    }

    var hasLoadedAudioQueue: Bool { player != nil }

    var inAppPlaybackRequestState: InAppPlaybackRequest.State {
        .init(isPlaying: isPlaying, hasAudioQueue: hasLoadedAudioQueue,
              isConverting: isConverting, hasPlayableChapters: snapshot?.playableChapters.isEmpty == false,
              usesSpeechFallback: isUsingSpeechFallback)
    }

    // MARK: - Speech fallback (slice 2)

    func shouldUseSpeechFallback(for snapshot: JobSnapshot?, chapterIndex: Int) -> Bool {
        SpeechPlaybackRoute.shouldUseSpeechFallback(for: snapshot, chapterIndex: chapterIndex)
    }
    func playFallbackSpeech(text: String, languageCode: String? = nil) {
        services.transport.playFallbackSpeech(text: text, languageCode: languageCode)
    }

    typealias PlaybackAttemptResult = SpeechPlaybackRoute.AttemptResult

    /// Choose MP3 or chapter speech without granting implicit playback elsewhere.
    @discardableResult
    func playOrFallback(
        snapshot: JobSnapshot?, chapterIndex: Int, chapterText: String?, languageCode: String? = nil
    ) -> PlaybackAttemptResult {
        return services.transport.playOrFallback(snapshot: snapshot, chapterIndex: chapterIndex, chapterText: chapterText, languageCode: languageCode)
    }

    typealias PlayTapDecision = ChapterNavigationDecision.PlayTapDecision

    func playTapDecision(readerChapterIndex: Int, readerPageRatio: Double? = nil) -> PlayTapDecision {
        services.navigation.playTapDecision(readerChapterIndex: readerChapterIndex, readerPageRatio: readerPageRatio,
            snapshot: snapshot, isPlaying: isPlaying, hasPausedPlaybackToResume: hasPausedPlaybackToResume,
            isSegmentMode: isSegmentMode, hasPlayer: player != nil, currentChapterIndex: currentChapterIndex)
    }

    var speechOutput: SpeechFallbackPlayer { services.speech }

    func setSentenceTiming(_ map: [String: Int], forChapterIndex chapterIndex: Int) {
        services.reader.setTiming(map, forChapterIndex: chapterIndex)
    }

    /// The active reader can replace partial audio using a fresh Rust text range.
    var restartReaderListening: ((Int, Double) -> Bool)?

    func startFromReaderPage(
        _ readerChapterIndex: Int, sentenceId: String? = nil,
        sentenceOffsetRatio: Double? = nil, sentenceWordOffsetRatio: Double? = nil
    ) {
        let ratio = sentenceOffsetRatio ?? 0
        if ratio.isFinite, (0...1).contains(ratio),
           restartReaderListening?(readerChapterIndex, ratio) == true { return }
        services.seeking.startFromReaderPage(readerChapterIndex, sentenceId: sentenceId,
            sentenceOffsetRatio: sentenceOffsetRatio, sentenceWordOffsetRatio: sentenceWordOffsetRatio)
    }

    func togglePlayPause() { isPlaying ? pause() : resume() }

    /// Only the active listening coordinator can fulfill a text-range restart.
    var approximateSeekJobID: String?
    var isPositionApproximate: Bool {
        if case .approximateTime = pendingNavigation?.target { return true }
        return isSegmentMode && services.segments.startingPosition(for: currentChapterIndex) > 0
    }
    func seek(to seconds: TimeInterval) {
        narrationJumps.send()
        services.seeking.seek(to: seconds,
            allowsApproximation: approximateSeekJobID != nil && approximateSeekJobID == snapshot?.jobId)
    }

    func pendingListeningSeek(for navigation: PendingNavigation) -> PendingPlaybackSeek.ChapterRequest? {
        guard let request = pendingSeek.chapter, request.id == navigation.requestID,
              request.jobID == navigation.jobID, snapshot?.jobId == navigation.jobID,
              request.chapterIndex == navigation.chapterIndex,
              (request.navigationTarget ?? .chapterTime(request.position)) == navigation.target else { return nil }
        return request
    }

    func restoreListeningSeek(_ request: PendingPlaybackSeek.ChapterRequest, jobID: String) {
        guard snapshot?.jobId == jobID else { return }
        isSegmentMode = true
        services.seeking.restoreListeningSeek(request, jobID: jobID)
    }

    func cancelPendingListeningSeek(_ request: PendingPlaybackSeek.ChapterRequest) {
        guard pendingSeek.chapter?.id == request.id, pendingSeek.chapter?.jobID == request.jobID else { return }
        services.seeking.cancel()
    }

    func nextChapter() {
        narrationJumps.send()
        services.transport.navigateChapter(.forward)
    }

    func previousChapter(restartsCurrentChapter: Bool = true) {
        narrationJumps.send()
        services.transport.navigateChapter(.backward, restartsCurrentChapter: restartsCurrentChapter)
    }

    func setRate(_ rate: PlaybackRate) {
        services.transport.setRate(rate)
    }

    nonisolated static func rateAdjustedDuration(seconds: TimeInterval, rate: PlaybackRate) -> TimeInterval{ PlaybackChapterQueue.rateAdjustedDuration(seconds: seconds, rate: rate) }

    var playbackDurationSeconds: TimeInterval {
        Self.rateAdjustedDuration(seconds: durationSeconds, rate: rate)
    }

    var playbackPositionSeconds: TimeInterval {
        Self.rateAdjustedDuration(seconds: positionSeconds, rate: rate)
    }
    func skip(by deltaSeconds: TimeInterval) {
        narrationJumps.send()
        services.transport.skip(by: deltaSeconds)
    }

    func streamRequestAuthorization(
        jobID: String, generation: UUID, chapterIndex: Int, segmentIndex: Int,
        session: StreamingDiagnosticsSession = .shared
    ) -> StreamingDiagnosticsSession.Authorization? {
        guard generation == remoteSegmentGeneration, let snapshot else { return nil }
        return services.stream.authorization(jobID: jobID, chapterIndex: chapterIndex, segmentIndex: segmentIndex,
            snapshot: snapshot, pendingChapter: pendingSeek.chapter, hasPlayer: player != nil,
            pendingAutoplay: pendingAutoPlay, session: session)
    }

    func enqueueRemoteSegment(
        data: Data, jobID: String, generation: UUID, chapterIndex: Int, segmentIndex: Int,
        publication: LatencyObservation.StreamPublication?,
        receipt: LatencyObservation.StreamRequestReceipt? = nil
    ) {
        guard generation == remoteSegmentGeneration, snapshot?.jobId == jobID else { return }
        enqueueSegment(data: data, chapterIndex: chapterIndex, segmentIndex: segmentIndex,
                       publication: publication, receipt: receipt)
    }

    /// Production callers await this acknowledgement before downloading more
    /// bytes. A stale completion must never attach audio to another session.
    func enqueueRemoteSegmentAsync(
        data: Data, jobID: String, generation: UUID, chapterIndex: Int, segmentIndex: Int,
        publication: LatencyObservation.StreamPublication?,
        receipt: LatencyObservation.StreamRequestReceipt? = nil
    ) async -> Bool {
        guard generation == remoteSegmentGeneration, snapshot?.jobId == jobID else { return false }
        return await enqueueSegmentAsync(data: data, chapterIndex: chapterIndex, segmentIndex: segmentIndex,
                                         publication: publication, receipt: receipt)
    }

    func enqueueSegmentAsync(
        data: Data, chapterIndex: Int, segmentIndex: Int, sentenceId: String? = nil,
        publication: LatencyObservation.StreamPublication? = nil,
        receipt: LatencyObservation.StreamRequestReceipt? = nil,
        maximumDeferredSegments: Int = SegmentBacklog.maximumDeferredSegmentCount
    ) async -> Bool {
        await services.stream.enqueueAsync(data: data,
            identity: .init(chapterIndex: chapterIndex, segmentIndex: segmentIndex),
            generation: remotePlaybackGeneration, sentenceID: sentenceId,
            publication: publication, receipt: receipt, maximumDeferredSegments: maximumDeferredSegments)
    }

    func enqueueSegment(
        data: Data, chapterIndex: Int, segmentIndex: Int, sentenceId: String? = nil,
        publication: LatencyObservation.StreamPublication? = nil,
        receipt: LatencyObservation.StreamRequestReceipt? = nil
    ) {
        services.stream.enqueue(data: data, identity: .init(chapterIndex: chapterIndex, segmentIndex: segmentIndex),
                                sentenceID: sentenceId, publication: publication, receipt: receipt)
    }

    func activateQueue(_ queue: AVQueuePlayer) {
        ensureAudioSession()
        queue.rate = rate.rawValue
        isPlaying = true
        pendingAutoPlay = false
    }

    func waitForSegmentCapacity(maximumCount: Int = SegmentBacklog.maximumDeferredSegmentCount) async -> Bool {
        await services.segments.waitForCapacity(maximumCount: maximumCount)
    }

    func markFirstChapterReady() { services.readiness.markFirstChapterReady() }

    func beginPlaybackPreparation() { services.readiness.beginPlaybackPreparation() }

    func clearConversionState() {
        services.readiness.reset(clearLatches: !isPlaying && player == nil)
    }
    func stop() {
        services.lifecycle.stop()
    }

    func setSleepTimer(seconds: TimeInterval) {
        services.sleep.set(seconds: seconds)
    }

    func startSleepTimer(minutes: Int) {
        services.sleep.start(minutes: minutes)
    }
    func skipForward(seconds: Double? = nil) {
        narrationJumps.send()
        services.transport.skipForward(seconds: seconds)
    }
    func skipBackward(seconds: Double? = nil) {
        narrationJumps.send()
        services.transport.skipBackward(seconds: seconds)
    }

    /// Refreshes Control Center and Lock Screen intervals after a Settings change.
    func refreshRemoteSkipIntervals() { PlaybackSystemSession.refreshSkipIntervals() }

    // MARK: Now Playing / Remote commands

    func makeNowPlayingInfo() -> [String: Any] {
        return services.observation.makeNowPlayingInfo()
    }
    private func updateNowPlayingInfo() {
        services.observation.updateNowPlayingInfo()
    }

    // MARK: Helpers


    func updateReaderChapterTitle(_ title: String, for index: Int) {
        services.observation.updateReaderChapterTitle(title, for: index)
    }
    func updateReaderChapterTitles(_ chapters: [EbookFulltext.Chapter]) {
        services.observation.updateReaderChapterTitles(chapters)
    }

    func persistResumePoint(force: Bool) {
        services.observation.persistResumePoint(force: force)
    }
    func prepareSegmentRestart(resumePosition: TimeInterval? = nil) {
        services.lifecycle.prepareSegmentRestart(resumePosition: resumePosition)
    }

    private var pendingAutoPlay: Bool = false { didSet { scheduleTransportPublication() } }
    private var pendingSegmentResumePosition: TimeInterval?
}
