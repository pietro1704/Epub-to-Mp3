import Combine
import Foundation

/// Owns one requested listening job, its playback window and stale-callback rejection.
@MainActor
final class ReaderListeningSession {
    enum ChapterDelivery {
        case requestedChapter
        case playbackWindow
    }

    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private let currentBookID: () -> String?
    private let openBook: (String) async throws -> URL
    private let recordConversion: (String, String) -> Void
    private let reportFailure: (Error) -> Void
    private let chapterDelivery: ChapterDelivery
    private let bindPlayback: (String, Int) -> Void
    private let makePlaybackControl: @MainActor () throws -> ConverterPlaybackControl
    private var cancellables: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private(set) var listeningJobID: String?
    private var pendingRestartJobID: String?
    private(set) var listeningBookID: String?
    private var listeningPlaybackControl: ConverterPlaybackControl?
    private var listeningChapters: [JobSnapshot.Chapter] = []
    private var hasDeliveredListeningChapter = false
    private var hasPublishedChapter = false
    private var requestedPDFPosition: (chapter: Int, offset: Int)?
    private(set) var requestedVoice: TtsSelection?
    private var voiceChangeInPreparation: ReaderVoiceChange?
    /// The job the player still shows while a replacement (voice change, restart) is being prepared. Its snapshot
    /// is not a sign that another owner took the player over, so it must not cancel the replacement.
    private var retiringPlayerJobID: String?
    var startingVoicePosition: ReaderVoiceChange? {
        guard listeningJobID != nil, let requestedPage else { return nil }
        if player.snapshot?.jobId == listeningJobID {
            guard player.isConverting, !hasDeliveredListeningChapter, player.pendingNavigation == nil else { return nil }
            return .init(chapter: requestedPage.chapter, pageRatio: requestedPage.ratio,
                seek: nil, autoplay: player.hasPendingAutoplay, sourceScalarOffset: requestedPDFPosition?.offset)
        }
        return voiceChangeInPreparation ?? .init(chapter: requestedPage.chapter, pageRatio: requestedPage.ratio,
            seek: nil, autoplay: true, sourceScalarOffset: requestedPDFPosition?.offset)
    }

    private var requestedPage: (chapter: Int, ratio: Double)?
    private var chapterEstimates: [Int: TimeInterval] = [:]
    private var restartListening: ((Int, Double, PendingPlaybackSeek.ChapterRequest?) -> Void)?

    init(player: AudioPlayer, playerPresentation: PlayerPresentation,
         conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor,
         currentBookID: @escaping () -> String?,
         openBook: @escaping (String) async throws -> URL,
         recordConversion: @escaping (String, String) -> Void,
         reportFailure: @escaping (Error) -> Void,
         chapterDelivery: ChapterDelivery = .requestedChapter,
         bindPlayback: @escaping (String, Int) -> Void = { _, _ in },
         makePlaybackControl: (@MainActor () throws -> ConverterPlaybackControl)? = nil) {
        self.player = player
        self.playerPresentation = playerPresentation
        self.conversionExecutor = conversionExecutor
        self.currentBookID = currentBookID
        self.openBook = openBook
        self.recordConversion = recordConversion
        self.reportFailure = reportFailure
        self.chapterDelivery = chapterDelivery
        self.bindPlayback = bindPlayback
        self.makePlaybackControl = makePlaybackControl ?? { try RustConversionCoordinator.makePlaybackControl() }
    }

    convenience init(player: AudioPlayer, playerPresentation: PlayerPresentation,
                     conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor,
                     currentBookID: @escaping () -> String?, library: @escaping () -> LibraryStore?,
                     reportFailure: @escaping (Error) -> Void) {
        self.init(player: player, playerPresentation: playerPresentation, conversionExecutor: conversionExecutor,
            currentBookID: currentBookID, openBook: { id in
                guard let activeLibrary = library() else { throw CancellationError() }
                return try await activeLibrary.openBookFileAsync(id: id)
            }, recordConversion: { jobID, bookID in
                library()?.recordConversion(jobId: jobID, for: bookID)
            }, reportFailure: reportFailure)
    }

    func voicePickerContext(for book: BookEntity) -> ReaderVoicePickerRequest.Context {
        guard isListening(to: book.id) else { return .init(book: book) }
        return .init(book: book, jobID: listeningJobID, requestedVoice: requestedVoice,
            startingPosition: startingVoicePosition, pdfPosition: requestedPDFPosition)
    }

    func isListening(to bookID: String) -> Bool {
        listeningJobID != nil && listeningBookID == bookID
    }

    func ownsPlaybackJob(_ jobID: String, for bookID: String) -> Bool {
        listeningJobID == jobID && listeningBookID == bookID
    }

    func waitForCompletion() async { await task?.value }

    func observePlayback() {
        guard cancellables.isEmpty else { return }
        player.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let snapshot, let jobID = self.listeningJobID,
                      snapshot.jobId != jobID, snapshot.jobId != self.retiringPlayerJobID else { return }
                self.cancel()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let playingBook = self.listeningBookID
                        ?? self.player.location.playingBookID
                    guard bookID == nil || playingBook == bookID else { return }
                    self.cancel()
                    self.player.stop()
                    self.player.clearConversionState()
                }
            }
            .store(in: &cancellables)
        player.$pendingNavigation
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] navigation in
                guard let self,
                      navigation.jobID == self.listeningJobID || navigation.jobID == self.pendingRestartJobID else { return }
                // A chapter request (next / previous, a contents pick) carries no listening seek; it still makes its
                // chapter the top priority of the streaming job.
                if navigation.jobID == self.listeningJobID, let control = self.listeningPlaybackControl {
                    StreamingSeekPriority.apply(navigation, to: control)
                }
                guard let request = self.player.pendingListeningSeek(for: navigation) else { return }
                if navigation.jobID == self.pendingRestartJobID {
                    switch navigation.target {
                    case .chapterTime: self.restartListening?(navigation.chapterIndex, 0, request)
                    case .readerPage(let ratio): self.restartListening?(navigation.chapterIndex, ratio, nil)
                    case .approximateTime(let ratio): self.restartListening?(navigation.chapterIndex, ratio, request)
                    }
                    return
                }
                guard let control = self.listeningPlaybackControl else { return }
                switch navigation.target {
                case .readerPage(let ratio):
                    guard ratio.isFinite, (0...1).contains(ratio) else { return }
                    if self.requestedPage?.chapter != navigation.chapterIndex || self.requestedPage?.ratio != ratio {
                        self.restartListening?(navigation.chapterIndex, ratio, nil)
                        return
                    }
                case .approximateTime(let ratio):
                    if !request.startsAtGeneratedOrigin {
                        self.restartListening?(navigation.chapterIndex, ratio, request)
                        return
                    }
                case .chapterTime:
                    if request.approximateRatio != nil { return }
                    // A text suffix has no measured absolute audio-time origin.
                    // Resolve a timeline seek from chapter start, carrying its
                    // exact seconds and current pause intent into the new job.
                    if self.requestedPDFPosition == nil,
                       self.requestedPage?.chapter == navigation.chapterIndex,
                       (self.requestedPage?.ratio ?? 0) > 0 {
                        self.restartListening?(navigation.chapterIndex, 0, request)
                        return
                    }
                }
                control.updatePlaybackWindow(currentChapter: navigation.chapterIndex, chaptersAhead: 1)
                _ = control.prioritize(chapterIndex: navigation.chapterIndex)
            }
            .store(in: &cancellables)
        player.$activeStreamingChapterIndex
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] chapterIndex in
                guard let self, self.listeningJobID != nil, self.player.pendingNavigation == nil,
                      let control = self.listeningPlaybackControl else { return }
                control.updatePlaybackWindow(currentChapter: chapterIndex, chaptersAhead: 1)
                _ = control.prioritize(chapterIndex: chapterIndex)
            }
            .store(in: &cancellables)

    }

    func cancel() {
        if player.approximateSeekJobID == listeningJobID { player.approximateSeekJobID = nil }
        task?.cancel()
        listeningJobID = nil
        pendingRestartJobID = nil
        listeningBookID = nil
        let retiring = listeningPlaybackControl
        listeningPlaybackControl = nil
        listeningChapters.removeAll()
        hasDeliveredListeningChapter = false
        hasPublishedChapter = false
        voiceChangeInPreparation = nil
        retiringPlayerJobID = nil
        requestedVoice = nil
        requestedPDFPosition = nil
        requestedPage = nil
        chapterEstimates.removeAll()
        restartListening = nil
        retiring?.cancel()
    }

    func start(book: BookEntity, priority: Int, pageRatio: Double?,
               catalog: [(index: Int, title: String)], conversionOptions: ConversionOptions,
               presentsFullPlayer: Bool, chapterEstimates: [Int: TimeInterval] = [:],
               pendingSeek: PendingPlaybackSeek.ChapterRequest? = nil,
               voiceChange: ReaderVoiceChange? = nil, pdfAnchor: PDFReadingAudioMap.Anchor? = nil,
               owner: AnyObject? = nil, showsPlayerOnCompletion: Bool = false) {
        cancel()
        guard let chapterStart = Int32(exactly: priority), chapterStart >= 0 else { return }
        // The playback control schedules only the active chapter and one ahead.
        let chapterEnd: Int32 = -1
        let jobID = UUID().uuidString
        let previousPlayerJob = player.snapshot?.jobId
        retiringPlayerJobID = previousPlayerJob
        listeningJobID = jobID
        pendingRestartJobID = pendingSeek?.jobID
        player.approximateSeekJobID = pendingSeek?.jobID
        listeningBookID = book.id
        requestedVoice = conversionOptions.ttsPreferences?.primary
        requestedPDFPosition = (voiceChange?.sourceScalarOffset ?? pdfAnchor?.sourceScalarOffset)
            .map { (priority, $0) }
        voiceChangeInPreparation = voiceChange
        self.chapterEstimates = chapterEstimates
        requestedPage = (priority, pageRatio ?? 0)
        restartListening = { [weak self, weak owner] chapter, ratio, request in
            guard let self else { return }
            let estimates = self.chapterEstimates
            self.start(book: book, priority: chapter, pageRatio: ratio, catalog: catalog,
                conversionOptions: conversionOptions, presentsFullPlayer: presentsFullPlayer,
                chapterEstimates: estimates, pendingSeek: request, owner: owner)
        }
        listeningChapters = catalog.map {
            JobSnapshot.Chapter(index: $0.index, name: $0.title, status: "pending",
                downloadUrl: nil, chars: nil, charsProcessed: nil, progressRatio: nil,
                durationSeconds: nil, startedAt: nil, completedAt: nil)
        }
        task = Task { [weak self, owner] in
            guard let self else { return }
            defer { withExtendedLifetime(owner) {} }
            var installedPending = false
            defer {
                if self.listeningJobID == jobID {
                    if self.player.approximateSeekJobID == jobID { self.player.approximateSeekJobID = nil }
                    self.listeningJobID = nil
                    self.pendingRestartJobID = nil
                    self.listeningBookID = nil
                    self.listeningPlaybackControl = nil
                }
            }
            do {
                guard listeningJobID == jobID, !Task.isCancelled else { return }
                let url = try await openBook(book.id)
                guard listeningJobID == jobID, !Task.isCancelled, currentBookID() == book.id,
                      player.snapshot?.jobId == previousPlayerJob else { return }
                let carriedSeek: PendingPlaybackSeek.ChapterRequest?
                if let pendingSeek {
                    guard let navigation = player.pendingNavigation, navigation.jobID == pendingSeek.jobID,
                          let current = player.pendingListeningSeek(for: navigation) else { return }
                    switch navigation.target {
                    case .chapterTime:
                        if current.chapterIndex != priority {
                            restartListening?(current.chapterIndex, 0, current)
                            return
                        }
                    case .approximateTime(let ratio):
                        if current.chapterIndex != priority || ratio != pageRatio {
                            restartListening?(current.chapterIndex, ratio, current)
                            return
                        }
                    case .readerPage(let ratio):
                        restartListening?(current.chapterIndex, ratio, nil)
                        return
                    }
                    var restored = current
                    if case .approximateTime = navigation.target {
                        restored.startsAtGeneratedOrigin = true
                        restored.approximateRatio = nil
                    }
                    carriedSeek = restored
                } else { carriedSeek = voiceChange?.seek }
                let playbackControl = try makePlaybackControl()
                playbackControl.updatePlaybackWindow(currentChapter: priority, chaptersAhead: 1)
                if let offset = voiceChange?.sourceScalarOffset ?? pdfAnchor?.sourceScalarOffset {
                    playbackControl.startFromPage(sourceScalarOffset: offset)
                } else if let pageRatio {
                    playbackControl.startFromPage(ratio: pageRatio)
                }
                playbackControl.trackPlayback(player)
                listeningPlaybackControl = playbackControl
                let pending = JobSnapshot.listeningPending(
                    jobID: jobID, bookTitle: book.resolvedTitle, bookAuthor: book.author, chapters: self.listeningChapters
                )
                pendingRestartJobID = nil
                if player.positionSeconds > 1 {
                    player.pause()
                    player.persistResumePoint(force: true)
                }
                player.stop()
                bindPlayback(book.id, priority)
                player.playbackClock.audioOutput.bindReaderJob(pending.jobId, to: book.id)
                player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
                updateChapterEstimates(self.chapterEstimates, for: book.id)
                player.approximateSeekJobID = jobID
                installedPending = true
                retiringPlayerJobID = nil
                player.isConverting = true
                if let carriedSeek { player.restoreListeningSeek(carriedSeek, jobID: jobID) }
                else if voiceChange?.autoplay != false { player.resume() }
                let chunkDelivery = StreamingPlaybackChunkDelivery(player: player)
                let result = try await conversionExecutor(
                    url, jobID, chapterStart, chapterEnd, playbackControl,
                    conversionOptions,
                    { [weak self] event in
                        guard let self, event.jobId == jobID,
                              self.ownsInstalledJob(jobID), let current = self.player.snapshot else { return }
                        if self.chapterDelivery == .playbackWindow, event.state != "running" { return }
                        self.player.updateSnapshot(event.updating(current))
                    },
                    { [weak self] event in
                        guard let self, event.jobId == jobID, self.ownsInstalledJob(jobID) else { return }
                        self.publishChapter(event, bookID: book.id, priority: priority,
                                            presentsFullPlayer: presentsFullPlayer)
                    },
                    { [weak self] chapterIndex, chunkIndex, data in
                        guard let self else { return false }
                        return chunkDelivery.enqueue(
                            data,
                            chapterIndex: chapterIndex,
                            chunkIndex: chunkIndex,
                            buffersAudio: true,
                            isCurrent: { [weak self] in
                                guard let self else { return false }
                                return self.ownsInstalledJob(jobID)
                                    && (self.hasDeliveredListeningChapter || self.currentBookID() == book.id)
                                    && playbackControl.acceptsChunks(forChapter: chapterIndex)
                            },
                            onAccepted: { [weak self] in
                                guard let self, self.ownsInstalledJob(jobID) else { return }
                                self.hasDeliveredListeningChapter = true
                            }
                        )
                    }
                )
                guard ownsInstalledJob(jobID) else { return }
                let snapshot = try result.snapshot()
                guard result.jobID == jobID, snapshot.jobId == jobID else {
                    throw EmbeddedConverterError.conversionFailed("Conversion returned a different listening job.")
                }
                if chapterDelivery == .requestedChapter {
                    let indices = snapshot.playableChapters.map(\.index)
                    guard indices.first == priority, indices == indices.sorted(), Set(indices).count == indices.count else {
                        throw EmbeddedConverterError.conversionFailed("Conversion did not preserve the requested chapter order.")
                    }
                }
                recordConversion(result.jobID, book.id)
                guard ownsInstalledJob(jobID) else { return }
                let showsCurrentBook = currentBookID() == book.id
                if !hasDeliveredListeningChapter, !showsCurrentBook { player.pause() }
                player.finishStreaming(snapshot: snapshot)
                if showsCurrentBook, showsPlayerOnCompletion { playerPresentation.showFullPlayer() }
            } catch {
                guard listeningJobID == jobID else { return }
                guard player.snapshot?.jobId == (installedPending ? jobID : previousPlayerJob) else { return }
                listeningPlaybackControl?.cancel()
                if !installedPending, let pendingSeek { concludeFailedRestart(error, previousJobID: pendingSeek.jobID) }
                concludeFailedListening(error, jobID: jobID)
                guard currentBookID() == book.id else { return }
                reportFailure(error)
            }
        }
    }

    private func ownsInstalledJob(_ jobID: String) -> Bool {
        listeningJobID == jobID && player.snapshot?.jobId == jobID
    }

    private func publishChapter(_ event: RustConversionCoordinator.ChapterCompletionEvent,
                                bookID: String, priority: Int, presentsFullPlayer: Bool) {
        switch chapterDelivery {
        case .requestedChapter:
            guard event.chapterIndex >= priority, event.audioPath.isFileURL,
                  FileManager.default.isReadableFile(atPath: event.audioPath.path) else { return }
        case .playbackWindow:
            guard listeningPlaybackControl?.acceptsChunks(forChapter: event.chapterIndex) == true else { return }
        }
        guard hasDeliveredListeningChapter || currentBookID() == bookID else {
            player.pause()
            return
        }

        let chapter = event.playableChapter
        if let index = listeningChapters.firstIndex(where: { $0.index == chapter.index }) {
            listeningChapters[index] = chapter
        } else {
            listeningChapters.append(chapter)
        }
        listeningChapters.sort { $0.index < $1.index }
        if chapterDelivery == .requestedChapter,
           !listeningChapters.contains(where: { $0.index == priority && $0.downloadUrl != nil }) { return }

        player.updateSnapshot(event.snapshot(chapters: listeningChapters, preserving: player.snapshot))
        let firstPresentation = chapterDelivery == .playbackWindow ? !hasPublishedChapter : !hasDeliveredListeningChapter
        if presentsFullPlayer, firstPresentation, currentBookID() == bookID {
            playerPresentation.showFullPlayer()
        }
        hasPublishedChapter = true
        hasDeliveredListeningChapter = true
    }

    func updateChapterEstimates(_ estimates: [Int: TimeInterval], for bookID: String) {
        guard listeningBookID == bookID, let jobID = listeningJobID else { return }
        chapterEstimates.merge(estimates, uniquingKeysWith: { _, new in new })
        guard player.snapshot?.jobId == jobID else { return }
        for (chapter, duration) in chapterEstimates {
            player.setSegmentChapterEstimate(duration, forChapterIndex: chapter,
                startingRatio: chapter == requestedPage?.chapter ? (requestedPage?.ratio ?? 0) : 0)
        }
    }

    private func concludeFailedRestart(_ error: Error, previousJobID: String) {
        guard let navigation = player.pendingNavigation, navigation.jobID == previousJobID,
              let request = player.pendingListeningSeek(for: navigation) else { return }
        player.cancelPendingListeningSeek(request)
        concludeFailedListening(error, jobID: previousJobID)
    }

    private func concludeFailedListening(_ error: Error, jobID: String) {
        guard let current = player.snapshot, current.jobId == jobID else { return }
        if !hasDeliveredListeningChapter { player.pause() }
        player.finishStreaming(snapshot: current.failed(error: error.localizedDescription))
    }
}
