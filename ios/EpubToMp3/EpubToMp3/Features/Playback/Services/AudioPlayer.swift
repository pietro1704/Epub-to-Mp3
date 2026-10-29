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
        didSet { services.bookProgress.update(snapshot) }
    }

    var cachedBookChapterProgress: BookChapterProgress? { services.bookProgress.value }
    var currentChapterIndex: Int { services.queue.currentChapterIndex }
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

    /// Ordered list of playback rates available in the UI.
    let availableRates: [Float] = PlaybackRate.primaryRates.map(\.rawValue)

    // MARK: AsyncStreams (positions + chapter changes)

    var currentChapter: AsyncStream<JobSnapshot.Chapter?> { services.broadcast.chapters(initial: services.observation.currentChapterValue) }
    var position: AsyncStream<TimeInterval> { services.broadcast.positions(initial: positionSeconds) }

    // MARK: Internals

    /// Mutable backend base URL for relative artifact paths.
    var backendBaseURL: URL?
    // Segment-mode cumulative position tracking: AVQueuePlayer reports
    // per-item position, but SyncEngine needs chapter-relative time.
    private var isSegmentMode = false
    /// Invalidates remote deliveries after stop or transport replacement, even
    /// when a newly opened session has the same backend job identifier.
    private(set) var remotePlaybackGeneration = UUID()
    var remoteSegmentGeneration: UUID? {
        player == nil || isSegmentMode ? remotePlaybackGeneration : nil
    }

    typealias RouteChangeReason = PlaybackSystemSession.RouteChangeReason


    /// Shared only with transport surfaces, separate from structural publication.
    let playbackClock: PlaybackClock

    @Published private(set) var isUsingSpeechFallback: Bool = false

    private let configuration: PlaybackServices.Configuration
    private lazy var services: PlaybackServices = PlaybackServices(authority: self, configuration: configuration)

    init(
        resumeStore: ResumeStore = ResumeStore(),
        backendBaseURL: URL? = nil,
        speechFallback: SpeechFallbackPlayer? = nil,
        playbackClock: PlaybackClock? = nil,
        artifactStore: LocalAudioArtifactStore? = nil,
        segmentFileWriter: SegmentFileWriter? = nil
    ) {
        let clock = playbackClock ?? PlaybackClock()
        self.playbackClock = clock
        configuration = .init(resumeStore: resumeStore, speech: speechFallback, clock: clock,
                              artifacts: artifactStore, writer: segmentFileWriter)
        self.backendBaseURL = backendBaseURL
        // Synchronous forwarding preserves old-value ordering and every assignment.
        readinessObservation = services.readiness.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        queueObservation = services.queue.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // The composition graph can only publish through these narrow authority
    // methods. It never stores another copy of intent or generation.
    var usesSegmentQueue: Bool { isSegmentMode }
    var hasPendingAutoplay: Bool { pendingAutoPlay }
    var pendingPlaybackResumePosition: TimeInterval? { pendingSegmentResumePosition }
    func playbackSnapshotChanged(_ value: JobSnapshot?) { snapshot = value }
    func playbackPlayingChanged(_ value: Bool) { isPlaying = value }
    func playbackSeekingChanged(_ value: Bool) { isSeeking = value }
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

    func updateSnapshot(_ snapshot: JobSnapshot) { services.chapter.updateSnapshot(snapshot) }

    func finishStreaming(snapshot: JobSnapshot) { services.chapter.finishStreaming(snapshot: snapshot) }
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

    func seek(to seconds: TimeInterval) { services.seeking.seek(to: seconds) }

    func pendingListeningSeek(for navigation: PendingNavigation) -> PendingPlaybackSeek.ChapterRequest? {
        guard let request = pendingSeek.chapter, request.id == navigation.requestID,
              request.jobID == navigation.jobID, snapshot?.jobId == navigation.jobID else { return nil }
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

    func nextChapter() { services.transport.navigateChapter(.forward) }

    func previousChapter() { services.transport.navigateChapter(.backward) }

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

    func recordConversionError(_ message: String) { services.readiness.recordConversionError(message) }

    var conversionStatus: ConversionStatus { services.readiness.status }

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

    func cancelSleepTimer() {
        services.sleep.cancel()
    }
    func cycleRate() {
        services.transport.cycleRate()
    }
    func skipForward(seconds: Double? = nil) {
        services.transport.skipForward(seconds: seconds)
    }
    func skipBackward(seconds: Double? = nil) {
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

    private var pendingAutoPlay: Bool = false
    private var pendingSegmentResumePosition: TimeInterval?

    // MARK: - Test hooks
    //
    #if DEBUG
    private lazy var testAccess: PlaybackTestAccess = PlaybackTestAccess(authority: self, services: services)
    func testHook_setIsPlaying(_ value: Bool) { testAccess.setIsPlaying(value) }
    func testHook_currentPlayerItem() -> AVPlayerItem? { testAccess.currentPlayerItem() }
    func testHook_setSnapshot(_ snap: JobSnapshot) { testAccess.setSnapshot(snap) }
    func testHook_setCurrentChapterIndex(_ idx: Int) { testAccess.setCurrentChapterIndex(idx) }
    func testHook_setDurationSeconds(_ value: Double) { testAccess.setDurationSeconds(value) }
    func testHook_playbackChapterCount() -> Int { testAccess.playbackChapterCount() }

    func testHook_sentenceTimingMap(forChapterIndex idx: Int) -> [String: Int]? { testAccess.sentenceTimingMap(forChapterIndex: idx) }
    func testHook_activeSegmentIdentity() -> SegmentBacklog.Identity? { testAccess.activeSegmentIdentity() }
    func testHook_deferredSegmentCount() -> Int { testAccess.deferredSegmentCount() }
    func testHook_retainedSegmentCount() -> Int { testAccess.retainedSegmentCount() }
    func testHook_segmentURL(chapterIndex: Int, segmentIndex: Int) -> URL? { testAccess.segmentURL(chapterIndex: chapterIndex, segmentIndex: segmentIndex) }
    func testHook_activateSegment(chapterIndex: Int, segmentIndex: Int) { testAccess.activateSegment(chapterIndex: chapterIndex, segmentIndex: segmentIndex) }
    func testHook_segmentChapterIndex() -> Int { testAccess.segmentChapterIndex() }
    func testHook_activeSegmentSentenceCount() -> Int { testAccess.activeSegmentSentenceCount() }
    func testHook_activateSegmentChapter(_ chapterIndex: Int) { testAccess.activateSegmentChapter(chapterIndex) }
    func testHook_bufferedSegmentChapterCount() -> Int { testAccess.bufferedSegmentChapterCount() }
    func testHook_completeSegmentTiming(chapterIndex: Int) { testAccess.completeSegmentTiming(chapterIndex: chapterIndex) }
    func testHook_registerOwnedSegmentItem(_ item: AVPlayerItem) { testAccess.registerOwnedSegmentItem(item) }
    func testHook_isOwnedSegmentItem(_ item: AVPlayerItem) -> Bool { testAccess.isOwnedSegmentItem(item) }
    func testHook_removeOwnedSegmentItem(_ item: AVPlayerItem) { testAccess.removeOwnedSegmentItem(item) }
    func testHook_backlogCount() -> Int { testAccess.backlogCount() }
    func testHook_segmentCapacityWaiterCount() -> Int { testAccess.segmentCapacityWaiterCount() }
    func testHook_segmentTempDirectory() -> URL? { testAccess.segmentTempDirectory() }

    func testHook_teardownPlayer() { testAccess.teardownPlayer() }
    func testHook_finishCurrentSegment() -> Bool { testAccess.finishCurrentSegment() }
    func testHook_simulateSegmentMode() { testAccess.simulateSegmentMode() }
    #endif
}
