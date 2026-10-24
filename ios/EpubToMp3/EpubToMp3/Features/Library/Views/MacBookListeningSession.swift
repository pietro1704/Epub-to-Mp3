#if os(macOS)
import AppKit
import Combine

/// Owns one book's listening generation and streaming callbacks independently of manual conversion.
@MainActor
final class MacBookListeningSession {
    private let book: BookEntity
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let streamingExecutor: RustConversionCoordinator.StreamingExecutor
    private let onShowJobs: () -> Void
    private let onError: (Error) -> Void
    private let onProgress: (Int?, String?) -> Void
    private var localPlaybackGeneration: String?
    private var localPlaybackChapters: [JobSnapshot.Chapter] = []
    private var localPlaybackControl: ConverterPlaybackControl?
    private var hasDeliveredLocalPlaybackSegment = false
    private var playbackCancellables: Set<AnyCancellable> = []

    init(book: BookEntity, library: LibraryStore, settings: AppSettings, player: AudioPlayer,
         playerPresentation: PlayerPresentation, streamingExecutor: @escaping RustConversionCoordinator.StreamingExecutor,
         onShowJobs: @escaping () -> Void, onError: @escaping (Error) -> Void,
         onProgress: @escaping (Int?, String?) -> Void) {
        self.book = book
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.streamingExecutor = streamingExecutor
        self.onShowJobs = onShowJobs
        self.onError = onError
        self.onProgress = onProgress
    }

    func observePlaybackChanges() {
        NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated {
                    guard let self, bookID == nil || bookID == self.book.id else { return }
                    let ownsPlayer = self.player.snapshot?.jobId == self.localPlaybackGeneration
                    self.onProgress(nil, "")
                    self.localPlaybackGeneration = nil
                    self.localPlaybackControl?.cancel()
                    self.localPlaybackControl = nil
                    if ownsPlayer { self.player.stop(); self.player.clearConversionState() }
                }
            }
            .store(in: &playbackCancellables)
        player.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let snapshot, let jobID = self.localPlaybackGeneration,
                      snapshot.jobId != jobID else { return }
                self.localPlaybackGeneration = nil
                self.localPlaybackControl?.cancel()
                self.localPlaybackControl = nil
            }
            .store(in: &playbackCancellables)
        player.$activeStreamingChapterIndex
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] chapterIndex in
                guard let self, self.localPlaybackGeneration != nil,
                      let control = self.localPlaybackControl else { return }
                control.updatePlaybackWindow(currentChapter: chapterIndex, chaptersAhead: 1)
                _ = control.prioritize(chapterIndex: chapterIndex)
            }
            .store(in: &playbackCancellables)
    }

    /// macOS starts local Rust streaming directly from Book Detail.
    func start() {
        guard localPlaybackGeneration == nil else { return }
        let jobID = UUID().uuidString
        localPlaybackGeneration = jobID
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                guard !Task.isCancelled, localPlaybackGeneration == jobID else { return }
                startRustStreaming(url: url, jobID: jobID)
            } catch {
                guard !Task.isCancelled, localPlaybackGeneration == jobID else { return }
                localPlaybackGeneration = nil
                onShowJobs()
            }
        }
    }

    private func startRustStreaming(url: URL, jobID: String) {
        guard localPlaybackGeneration == jobID else { return }
        localPlaybackControl?.cancel()
        let chapterStart = Int32(exactly: ReaderPlaybackPriorityChapter.index(bookID: book.id)) ?? 0
        do {
            let control = try RustConversionCoordinator.makePlaybackControl()
            control.trackPlayback(player)
            control.updatePlaybackWindow(currentChapter: Int(chapterStart), chaptersAhead: 1)
            localPlaybackControl = control
            localPlaybackGeneration = jobID
            onProgress(0, nil)
            localPlaybackChapters.removeAll()
            hasDeliveredLocalPlaybackSegment = false

            let pending = JobSnapshot(
                jobId: jobID,
                state: "running",
                bookTitle: book.resolvedTitle,
                bookAuthor: book.author,
                coverUrl: nil,
                coverMimeType: nil,
                engine: settings.audioEngine.rawValue,
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
        } catch {
            guard localPlaybackGeneration == jobID else { return }
            localPlaybackGeneration = nil
            onError(error)
            return
        }

        let chunkDelivery = StreamingPlaybackChunkDelivery(player: player)
        let conversionOptions = settings.conversionOptions
        Task { [weak self] in
            guard let self, let control = self.localPlaybackControl,
                  self.localPlaybackGeneration == jobID else { return }
            do {
                let result = try await streamingExecutor(
                url, jobID, chapterStart, -1, control,
                conversionOptions,
                    { [weak self] event in
                        guard let self, self.localPlaybackGeneration == jobID,
                              let snapshot = self.player.snapshot, snapshot.jobId == jobID else { return }
                        self.player.updateSnapshot(event.updating(snapshot))
                        if event.chaptersTotal > 0 {
                            let percent = Int(event.percent.rounded())
                            self.onProgress(percent, L10n.string("bookDetail.progressPercent", percent))
                        }
                    },
                    { [weak self] event in
                        guard let self, self.localPlaybackGeneration == jobID,
                              self.player.snapshot?.jobId == jobID else { return }
                        guard control.contains(chapterIndex: event.chapterIndex) else { return }
                        let chapter = event.playableChapter
                        if let existing = self.localPlaybackChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localPlaybackChapters[existing] = chapter
                        } else {
                            self.localPlaybackChapters.append(chapter)
                        }
                        self.localPlaybackChapters.sort { $0.index < $1.index }
                        let percent = Int(event.progressPercent.rounded())
                        self.onProgress(percent, L10n.string("bookDetail.progressPercent", percent))
                        self.player.updateSnapshot(event.snapshot(chapters: self.localPlaybackChapters, preserving: self.player.snapshot))
                    },
                    { [weak self] chapterIndex, chunkIndex, data in
                        guard let self else { return false }
                        return chunkDelivery.enqueue(
                            data,
                            chapterIndex: chapterIndex,
                            chunkIndex: chunkIndex,
                            isCurrent: { [weak self] in
                                guard let self, let control = self.localPlaybackControl else { return false }
                                return self.localPlaybackGeneration == jobID
                                    && self.player.snapshot?.jobId == jobID
                                    && control.contains(chapterIndex: chapterIndex)
                            },
                            onAccepted: { [weak self] in
                                guard let self, self.localPlaybackGeneration == jobID else { return }
                                if !self.hasDeliveredLocalPlaybackSegment {
                                    self.hasDeliveredLocalPlaybackSegment = true
                                    self.playerPresentation.showFullPlayer()
                                }
                            }
                        )
                    }
                )
                guard localPlaybackGeneration == jobID, player.snapshot?.jobId == jobID else { return }
                let snapshot = try result.snapshot()
                let indices = snapshot.playableChapters.map(\.index)
                guard result.jobID == jobID, snapshot.jobId == jobID,
                      indices.first == Int(chapterStart), indices == indices.sorted(),
                      Set(indices).count == indices.count else {
                    throw EmbeddedConverterError.conversionFailed(
                        "Conversion did not preserve the requested listening chapter order."
                    )
                }
                library.recordConversion(jobId: result.jobID, for: book.id)
                guard localPlaybackGeneration == jobID, player.snapshot?.jobId == jobID else { return }
                localPlaybackGeneration = nil
                localPlaybackControl = nil
                onProgress(100, L10n.string("bookDetail.progressPercent", 100))
                player.finishStreaming(snapshot: snapshot)
                playerPresentation.showFullPlayer()
            } catch {
                guard localPlaybackGeneration == jobID else { return }
                localPlaybackGeneration = nil
                localPlaybackControl?.cancel()
                localPlaybackControl = nil
                if let current = player.snapshot, current.jobId == jobID {
                    player.finishStreaming(snapshot: BookDetailConversionSnapshot.terminal(from: current, state: "failed", error: error.localizedDescription))
                }
                onError(error)
            }
        }
    }

}
#endif
