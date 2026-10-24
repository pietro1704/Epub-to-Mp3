#if os(macOS)
import AppKit

@MainActor
final class MacReaderPlaybackSession {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private(set) var localPlaybackBookID: String?
    private(set) var isStartingLocalPlayback = false
    private(set) var localPlaybackGeneration: String?
    private var localPlaybackChapters: [JobSnapshot.Chapter] = []
    private(set) var localPlaybackControl: ConverterPlaybackControl?

    init(settings: AppSettings, library: LibraryStore, player: AudioPlayer,
         playerPresentation: PlayerPresentation,
         conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.conversionExecutor = conversionExecutor
    }

    func start(owner: AnyObject) {
        playerPresentation.dismissFullPlayer()
        let defaults = UserDefaults.standard
        guard let bookID = defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              let book = library.books.first(where: { $0.id == bookID }) else { return }
        let chapterStart = Int32(exactly: ReaderPlaybackPriorityChapter.index(bookID: book.id)) ?? 0
        let pageRatio = defaults.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double
        cancel(stopPlayer: false)
        let jobID = UUID().uuidString
        localPlaybackGeneration = jobID
        localPlaybackBookID = bookID
        isStartingLocalPlayback = true
        let conversionOptions = settings.conversionOptions
        Task { [weak self, owner] in
            guard let self else { return }
            defer { withExtendedLifetime(owner) {} }
            defer {
                if localPlaybackGeneration == jobID {
                    localPlaybackGeneration = nil
                    localPlaybackBookID = nil
                    localPlaybackControl = nil
                    isStartingLocalPlayback = false
                }
            }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                guard localPlaybackGeneration == jobID, localPlaybackBookID == book.id else { return }
                localPlaybackChapters.removeAll()
                let playbackControl = try RustConversionCoordinator.makePlaybackControl()
                playbackControl.trackPlayback(player)
                playbackControl.updatePlaybackWindow(
                    currentChapter: Int(chapterStart),
                    chaptersAhead: 1
                )
                if let pageRatio { playbackControl.startFromPage(ratio: pageRatio) }
                localPlaybackControl = playbackControl
                let pending = JobSnapshot(
                    jobId: jobID,
                    state: "running",
                    bookTitle: book.resolvedTitle,
                    bookAuthor: book.author,
                    coverUrl: nil,
                    coverMimeType: nil,
                    engine: nil,
                    voice: nil,
                    language: nil,
                    progressPercent: 0,
                    chaptersTotal: nil,
                    chaptersCompleted: 0,
                    chapterProgress: [],
                    outputs: nil,
                    logUrl: nil,
                    error: nil,
                    lastActivityAt: Date().timeIntervalSince1970,
                    chapterIndexBase: 0
                )
                player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
                player.isConverting = true
                player.resume()
                let chunkDelivery = StreamingPlaybackChunkDelivery(player: player)
                isStartingLocalPlayback = false
                let result = try await conversionExecutor(
                    url, jobID, chapterStart, -1, playbackControl, conversionOptions,
                    { [weak self] event in
                        guard let self,
                              self.localPlaybackGeneration == jobID, event.jobId == jobID,
                              event.state == "running",
                              let snapshot = self.player.snapshot,
                              snapshot.jobId == jobID else { return }
                        self.player.updateSnapshot(event.updating(snapshot))
                    },
                    { [weak self] event in
                        guard let self, self.localPlaybackGeneration == jobID, event.jobId == jobID,
                              self.player.snapshot?.jobId == jobID else { return }
                        guard playbackControl.contains(chapterIndex: event.chapterIndex) else { return }
                        let firstPlayableChapter = self.localPlaybackChapters.isEmpty
                        let chapter = event.playableChapter
                        if let existing = self.localPlaybackChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localPlaybackChapters[existing] = chapter
                        } else {
                            self.localPlaybackChapters.append(chapter)
                        }
                        self.localPlaybackChapters.sort { $0.index < $1.index }
                        self.player.updateSnapshot(
                            event.snapshot(chapters: self.localPlaybackChapters, preserving: self.player.snapshot)
                        )
                        if firstPlayableChapter {
                            self.playerPresentation.showFullPlayer()
                        }
                    },
                    { chapterIndex, chunkIndex, data in
                        return chunkDelivery.enqueue(
                            data,
                            chapterIndex: chapterIndex,
                            chunkIndex: chunkIndex,
                            isCurrent: { [weak self] in
                                guard let self else { return false }
                                return self.localPlaybackGeneration == jobID
                                    && self.player.snapshot?.jobId == jobID
                                    && playbackControl.contains(chapterIndex: chapterIndex)
                            },
                            onAccepted: {}
                        )
                    }
                )
                guard localPlaybackGeneration == jobID, player.snapshot?.jobId == jobID else { return }
                let snapshot = try result.snapshot()
                guard result.jobID == jobID, snapshot.jobId == jobID else {
                    throw EmbeddedConverterError.conversionFailed("Conversion returned a different listening job.")
                }
                library.recordConversion(jobId: result.jobID, for: book.id)
                self.player.finishStreaming(snapshot: snapshot)
                self.playerPresentation.showFullPlayer()
            } catch {
                guard localPlaybackGeneration == jobID else { return }
                localPlaybackControl?.cancel()
                if let current = player.snapshot, current.jobId == jobID {
                    player.finishStreaming(snapshot: JobSnapshot(
                        jobId: current.jobId,
                        state: "failed",
                        bookTitle: current.bookTitle,
                        bookAuthor: current.bookAuthor,
                        coverUrl: current.coverUrl,
                        coverMimeType: current.coverMimeType,
                        engine: current.engine,
                        voice: current.voice,
                        language: current.language,
                        progressPercent: current.progressPercent,
                        chaptersTotal: current.chaptersTotal,
                        chaptersCompleted: current.chaptersCompleted,
                        chapterProgress: current.chapterProgress,
                        outputs: current.outputs,
                        logUrl: current.logUrl,
                        error: error.localizedDescription,
                        lastActivityAt: Date().timeIntervalSince1970,
                    chapterIndexBase: 0
                    ))
                }
                let alert = NSAlert()
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = AppErrorReporter.message(error, context: "Reader listening")
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    /// Invalidate before cancellation so retiring callbacks cannot touch a replacement session.
    func cancel(ifReplacingBook incomingBookID: String? = nil, stopPlayer: Bool = true) {
        guard localPlaybackGeneration != nil,
              incomingBookID == nil || incomingBookID != localPlaybackBookID else { return }
        localPlaybackGeneration = nil
        localPlaybackBookID = nil
        isStartingLocalPlayback = false
        let retiring = localPlaybackControl
        localPlaybackControl = nil
        localPlaybackChapters.removeAll()
        retiring?.cancel()
        if stopPlayer {
            player.stop()
            player.clearConversionState()
        }
    }

    func restorePlaybackIfPossible(owner: AnyObject, onRestored: @escaping @MainActor () -> Void) {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        guard let bookID else { return }
        let epubChapterIndex = UserDefaults.standard.object(
            forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey
        ) as? Int ?? 0
        Task { [weak self, owner] in
            guard let self else { return }
            defer { withExtendedLifetime(owner) {} }
            let embeddedSnapshot = try? await LocalAudioArtifactStore.shared.playableSnapshot(
                bookID: bookID,
                engine: settings.audioEngine.rawValue,
                voice: "auto",
                language: nil
            )
            let conversionJobID = library.books.first(where: { $0.id == bookID })?.lastJobId
            let restoredSnapshot: JobSnapshot?
            if let conversionJobID {
                restoredSnapshot = await Task.detached(priority: .utility) {
                    let converted = RustConversionCoordinator.persistedSnapshot(jobID: conversionJobID)
                    return AudiobookDownloadStorage.restoredPlaybackSnapshot(jobId: conversionJobID,
                                                                   conversionSnapshot: converted)
                }.value
            } else {
                restoredSnapshot = nil
            }
            guard localPlaybackGeneration == nil, player.snapshot == nil,
                  UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey) == bookID
                    || UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == bookID,
                  let snapshot = embeddedSnapshot ?? restoredSnapshot else {
                return
            }
            player.play(
                snapshot: snapshot,
                startingAt: AudioPlayer.restoredPlayableChapterOffset(
                    snapshot: snapshot,
                    persistedEpubChapterIndex: epubChapterIndex
                ),
                restoreAutoplay: false
            )
            onRestored()
        }
    }

}
#endif
