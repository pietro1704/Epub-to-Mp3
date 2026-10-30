#if os(iOS)
import Combine
import UIKit

/// Owns one requested listening job, its playback window and stale-callback rejection.
@MainActor
final class ReaderListeningSession {
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private let currentBookID: () -> String?
    private let openBook: (String) async throws -> URL
    private let recordConversion: (String, String) -> Void
    private let reportFailure: (Error) -> Void
    private let makePlaybackControl: @MainActor () throws -> ConverterPlaybackControl
    private var cancellables: Set<AnyCancellable> = []
    private var task: Task<Void, Never>?
    private var listeningJobID: String?
    private var pendingRestartJobID: String?
    private(set) var listeningBookID: String?
    private var listeningPlaybackControl: ConverterPlaybackControl?
    private var listeningChapters: [JobSnapshot.Chapter] = []
    private var hasDeliveredListeningChapter = false
    private var requestedPage: (chapter: Int, ratio: Double)?
    private var chapterEstimates: [Int: TimeInterval] = [:]
    private var restartListening: ((Int, Double, PendingPlaybackSeek.ChapterRequest?) -> Void)?

    init(player: AudioPlayer, playerPresentation: PlayerPresentation,
         conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor,
         currentBookID: @escaping () -> String?,
         openBook: @escaping (String) async throws -> URL,
         recordConversion: @escaping (String, String) -> Void,
         reportFailure: @escaping (Error) -> Void,
         makePlaybackControl: (@MainActor () throws -> ConverterPlaybackControl)? = nil) {
        self.player = player
        self.playerPresentation = playerPresentation
        self.conversionExecutor = conversionExecutor
        self.currentBookID = currentBookID
        self.openBook = openBook
        self.recordConversion = recordConversion
        self.reportFailure = reportFailure
        self.makePlaybackControl = makePlaybackControl ?? { try RustConversionCoordinator.makePlaybackControl() }
    }

    func isListening(to bookID: String) -> Bool {
        listeningJobID != nil && listeningBookID == bookID
    }

    func waitForCompletion() async { await task?.value }

    func observePlayback() {
        guard cancellables.isEmpty else { return }
        player.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let snapshot, let jobID = self.listeningJobID,
                      snapshot.jobId != jobID else { return }
                self.cancel()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let playingBook = self.listeningBookID
                        ?? UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
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
                      navigation.jobID == self.listeningJobID || navigation.jobID == self.pendingRestartJobID,
                      let request = self.player.pendingListeningSeek(for: navigation) else { return }
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
                    if self.requestedPage?.chapter == navigation.chapterIndex,
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
        requestedPage = nil
        chapterEstimates.removeAll()
        restartListening = nil
        retiring?.cancel()
    }

    func start(book: BookEntity, priority: Int, pageRatio: Double?,
               catalog: [(index: Int, title: String)], conversionOptions: ConversionOptions,
               presentsFullPlayer: Bool, chapterEstimates: [Int: TimeInterval] = [:],
               pendingSeek: PendingPlaybackSeek.ChapterRequest? = nil) {
        cancel()
        guard let chapterStart = Int32(exactly: priority), chapterStart >= 0 else { return }
        // The playback control schedules only the active chapter and one ahead.
        let chapterEnd: Int32 = -1
        let jobID = UUID().uuidString
        let previousPlayerJob = player.snapshot?.jobId
        listeningJobID = jobID
        pendingRestartJobID = pendingSeek?.jobID
        player.approximateSeekJobID = pendingSeek?.jobID
        listeningBookID = book.id
        self.chapterEstimates = chapterEstimates
        requestedPage = (priority, pageRatio ?? 0)
        restartListening = { [weak self] chapter, ratio, request in
            guard let self else { return }
            let estimates = self.chapterEstimates
            self.start(book: book, priority: chapter, pageRatio: ratio, catalog: catalog,
                conversionOptions: conversionOptions, presentsFullPlayer: presentsFullPlayer,
                chapterEstimates: estimates, pendingSeek: request)
        }
        listeningChapters = catalog.map {
            JobSnapshot.Chapter(index: $0.index, name: $0.title, status: "pending",
                downloadUrl: nil, chars: nil, charsProcessed: nil, progressRatio: nil,
                durationSeconds: nil, startedAt: nil, completedAt: nil)
        }
        hasDeliveredListeningChapter = false
        task = Task { [weak self] in
            guard let self else { return }
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
                let url = try await openBook(book.id)
                guard listeningJobID == jobID, currentBookID() == book.id,
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
                } else { carriedSeek = nil }
                let playbackControl = try makePlaybackControl()
                playbackControl.updatePlaybackWindow(currentChapter: priority, chaptersAhead: 1)
                if let pageRatio { playbackControl.startFromPage(ratio: pageRatio) }
                playbackControl.trackPlayback(player)
                listeningPlaybackControl = playbackControl
                let pending = JobSnapshot(jobId: jobID, state: "running", bookTitle: book.resolvedTitle,
                    bookAuthor: book.author, coverUrl: nil, coverMimeType: nil, engine: nil,
                    voice: nil, language: nil, progressPercent: 0, chaptersTotal: nil,
                    chaptersCompleted: 0, chapterProgress: self.listeningChapters, outputs: nil, logUrl: nil,
                    error: nil, lastActivityAt: Date().timeIntervalSince1970, chapterIndexBase: 0)
                pendingRestartJobID = nil
                if player.positionSeconds > 1 {
                    player.pause()
                    player.persistResumePoint(force: true)
                }
                player.stop()
                player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
                updateChapterEstimates(self.chapterEstimates, for: book.id)
                player.approximateSeekJobID = jobID
                installedPending = true
                player.isConverting = true
                if let carriedSeek { player.restoreListeningSeek(carriedSeek, jobID: jobID) }
                else { player.resume() }
                let chunkDelivery = StreamingPlaybackChunkDelivery(player: player)
                let result = try await conversionExecutor(
                    url, jobID, chapterStart, chapterEnd, playbackControl,
                    conversionOptions,
                    { [weak self] event in
                        guard let self, self.listeningJobID == jobID, event.jobId == jobID,
                              let current = self.player.snapshot, current.jobId == jobID else { return }
                        self.player.updateSnapshot(event.updating(current))
                    },
                    { [weak self] event in
                        guard let self, self.listeningJobID == jobID,
                              self.player.snapshot?.jobId == jobID, event.jobId == jobID,
                              event.chapterIndex >= priority, event.audioPath.isFileURL,
                              FileManager.default.isReadableFile(atPath: event.audioPath.path) else { return }
                        guard self.hasDeliveredListeningChapter || self.currentBookID() == book.id else {
                            self.player.pause()
                            return
                        }
                        let chapter = event.playableChapter
                        if let index = self.listeningChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.listeningChapters[index] = chapter
                        } else { self.listeningChapters.append(chapter) }
                        self.listeningChapters.sort { $0.index < $1.index }
                        guard self.listeningChapters.contains(where: { $0.index == priority && $0.downloadUrl != nil }) else { return }
                        self.player.updateSnapshot(event.snapshot(chapters: self.listeningChapters, preserving: self.player.snapshot))
                        if !self.hasDeliveredListeningChapter {
                            self.hasDeliveredListeningChapter = true
                            if presentsFullPlayer { self.playerPresentation.showFullPlayer() }
                        }
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
                                return self.listeningJobID == jobID
                                    && self.player.snapshot?.jobId == jobID
                                    && self.listeningPlaybackControl?.contains(chapterIndex: chapterIndex) == true
                            },
                            onAccepted: { [weak self] in
                                guard let self, self.listeningJobID == jobID else { return }
                                self.hasDeliveredListeningChapter = true
                            }
                        )
                    }
                )
                guard listeningJobID == jobID else { return }
                let snapshot = try result.snapshot()
                guard result.jobID == jobID, snapshot.jobId == jobID else {
                    throw EmbeddedConverterError.conversionFailed("Conversion returned a different listening job.")
                }
                let indices = snapshot.playableChapters.map(\.index)
                guard indices.first == priority, indices == indices.sorted(), Set(indices).count == indices.count else {
                    throw EmbeddedConverterError.conversionFailed("Conversion did not preserve the requested chapter order.")
                }
                recordConversion(result.jobID, book.id)
                guard listeningJobID == jobID, player.snapshot?.jobId == jobID else { return }
                if !hasDeliveredListeningChapter, currentBookID() != book.id {
                    player.pause()
                }
                player.finishStreaming(snapshot: snapshot)
            } catch let error as StoragePressureError {
                guard listeningJobID == jobID else { return }
                guard player.snapshot?.jobId == (installedPending ? jobID : previousPlayerJob) else { return }
                if !installedPending, let pendingSeek { concludeFailedRestart(error, previousJobID: pendingSeek.jobID) }
                concludeFailedListening(error, jobID: jobID)
                guard currentBookID() == book.id else { return }
                reportFailure(error)
            } catch {
                guard listeningJobID == jobID else { return }
                guard player.snapshot?.jobId == (installedPending ? jobID : previousPlayerJob) else { return }
                if !installedPending, let pendingSeek { concludeFailedRestart(error, previousJobID: pendingSeek.jobID) }
                concludeFailedListening(error, jobID: jobID)
                guard currentBookID() == book.id else { return }
                reportFailure(error)
            }
        }
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
        let failed = JobSnapshot(jobId: current.jobId, state: "failed", bookTitle: current.bookTitle,
            bookAuthor: current.bookAuthor, coverUrl: current.coverUrl, coverMimeType: current.coverMimeType,
            engine: current.engine, voice: current.voice, language: current.language,
            progressPercent: current.progressPercent, chaptersTotal: current.chaptersTotal,
            chaptersCompleted: current.chaptersCompleted, chapterProgress: current.chapterProgress,
            outputs: current.outputs, logUrl: current.logUrl, error: error.localizedDescription,
            lastActivityAt: Date().timeIntervalSince1970)
        player.finishStreaming(snapshot: failed)
    }
}
#endif
