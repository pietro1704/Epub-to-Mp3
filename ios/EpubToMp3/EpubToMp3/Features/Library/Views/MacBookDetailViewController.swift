#if os(macOS)
import AppKit
import Combine

/// macOS counterpart of `BookDetailScreenController` — the primary product
/// surface for an opened book (cover, progress, Read/Listen/Download)
/// instead of jumping straight into the chapter reader. Fills
/// `MacAppKitRootController`'s `detailContainer` between the Library grid
/// and the reader. See `docs/reader-spec-comparison.md` P0 gap #4.
@MainActor
final class MacBookDetailViewController: NSViewController {
    private let book: BookEntity
    private lazy var detailContent = MacBookDetailContent()
    private lazy var manualConversionPresentation = MacBookConversionPresentation(settings: settings)
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.Executor
    private let streamingExecutor: RustConversionCoordinator.StreamingExecutor
    private let onRead: (String) -> Void
    private let onShowJobs: () -> Void
    private let jobViewModel = JobDetailViewModel()
    private var playbackGeneration: UUID?
    private var streamDeliveryGeneration: UUID?
    private var autoPlayStream = false
    private var localConversionGeneration: String?
    private var localConversionProgress: Int?
    private var localConversionChapters: [JobSnapshot.Chapter] = []
    private var playbackCancellables: Set<AnyCancellable> = []

    private lazy var listeningSession = MacBookListeningSession(
        book: book, library: library, settings: settings, player: player,
        playerPresentation: playerPresentation, streamingExecutor: streamingExecutor,
        onShowJobs: onShowJobs,
        onError: { [weak self] error in self?.presentListenError(error) },
        onProgress: { [weak self] percent, message in
            self?.localConversionProgress = percent
            if let message { self?.detailContent.progressLabel.stringValue = message }
        }
    )

    init(
        book: BookEntity,
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        onRead: @escaping (String) -> Void,
        onShowJobs: @escaping () -> Void,
        conversionExecutor: @escaping RustConversionCoordinator.Executor = RustConversionCoordinator.execute,
        streamingExecutor: @escaping RustConversionCoordinator.StreamingExecutor = RustConversionCoordinator.executeStreaming
    ) {
        self.book = book
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.onRead = onRead
        self.onShowJobs = onShowJobs
        self.conversionExecutor = conversionExecutor
        self.streamingExecutor = streamingExecutor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }



    override func loadView() {
        view = detailContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureStreamingCallbacks()
        detailContent.recoveryPanel.onResume = { [weak self] options in
            self?.convertWholeBook(options: options)
        }
        observeLocalPlaybackChapterChanges()
        detailContent.readButton.target = self
        detailContent.pronunciationButton.target = self
        detailContent.pronunciationButton.action = #selector(editPronunciation)
        detailContent.readButton.action = #selector(tapRead)
        detailContent.listenButton.target = self
        detailContent.listenButton.action = #selector(tapListen)
        detailContent.convertButton.target = self
        detailContent.convertButton.action = #selector(tapConvert)
        detailContent.downloadButton.target = self
        detailContent.downloadButton.action = #selector(tapDownload)
        detailContent.logButton.target = self
        detailContent.logButton.action = #selector(tapLog)
        detailContent.render(book: book, localConversionProgress: localConversionProgress)
    }

    private func observeLocalPlaybackChapterChanges() {
        listeningSession.observePlaybackChanges()
        NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated {
                    guard let self, bookID == nil || bookID == self.book.id else { return }
                    self.localConversionGeneration = nil
                    self.localConversionProgress = nil
                    self.localConversionChapters.removeAll()
                    self.detailContent.progressLabel.stringValue = ""
                }
            }
            .store(in: &playbackCancellables)
    }

    private func configureStreamingCallbacks() {
        jobViewModel.onSnapshot = { [weak self] snapshot in
            guard let self else { return }
            if self.player.snapshot?.jobId == snapshot.jobId {
                self.player.updateSnapshot(snapshot)
                self.playbackGeneration = self.player.remotePlaybackGeneration
                return
            }
            guard !snapshot.isTerminal,
                  let baseURL = self.settings.resolvedBaseURL else { return }
            if self.player.beginRemoteStreaming(snapshot: snapshot, backendBaseURL: baseURL) {
                self.playbackGeneration = self.player.remotePlaybackGeneration
                self.streamDeliveryGeneration = self.player.remoteSegmentGeneration
                if self.autoPlayStream { self.player.resume() }
            }
        }
        jobViewModel.onStreamRequestAuthorization = { [weak self] jobID, chapterIndex, segmentIndex in
            guard let self, let generation = self.streamDeliveryGeneration else { return nil }
            return self.player.streamRequestAuthorization(
                jobID: jobID, generation: generation,
                chapterIndex: chapterIndex, segmentIndex: segmentIndex
            )
        }
        jobViewModel.onStreamChunk = { [weak self] data, chapterIndex, segmentIndex, publication, receipt in
            guard let self, let generation = self.streamDeliveryGeneration else { return false }
            return await self.player.enqueueRemoteSegmentAsync(
                data: data, jobID: self.jobViewModel.snapshot?.jobId ?? "",
                generation: generation, chapterIndex: chapterIndex,
                segmentIndex: segmentIndex, publication: publication, receipt: receipt
            )
        }
        jobViewModel.onStreamFinished = { [weak self] snapshot in
            guard let self,
                  self.player.snapshot?.jobId == snapshot.jobId,
                  self.playbackGeneration == self.player.remotePlaybackGeneration else { return }
            self.player.finishStreaming(snapshot: snapshot)
            self.playbackGeneration = self.player.remotePlaybackGeneration
        }
    }

    @objc private func tapRead() {
        onRead(book.id)
    }

    @objc private func editPronunciation() { BookPronunciationEditor.present(bookID: book.id, on: self) }

    /// macOS starts local Rust streaming directly from Book Detail.
    @objc private func tapListen() { listeningSession.start() }

    @objc private func tapConvert() {
        guard let options = manualConversionPresentation.chooseOptions() else { return }
        convertWholeBook(options: options)
    }

    func convertWholeBook() {
        tapConvert()
    }

    func convertWholeBook(options: ConversionOptions) {
        guard localConversionGeneration == nil else { return }
        let jobID = UUID().uuidString
        localConversionGeneration = jobID
        let selectedOptions = options
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                guard localConversionGeneration == jobID else { return }
                startRustConversion(url: url, jobID: jobID, options: selectedOptions)
            } catch {
                guard localConversionGeneration == jobID else { return }
                localConversionGeneration = nil
                presentListenError(error)
            }
        }
    }

    private func startRustConversion(url: URL, jobID: String, options: ConversionOptions) {
        guard localConversionGeneration == jobID else { return }
        localConversionProgress = 0
        localConversionChapters.removeAll()
        detailContent.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", 0)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await conversionExecutor(
                    url, jobID, -1, -1,
                    options,
                    { [weak self] event in
                        guard let self, self.localConversionGeneration == jobID else { return }
                        if let progress = event.renderProgress?.label {
                            self.detailContent.progressLabel.stringValue = progress
                        } else if event.message.hasPrefix("converting chapter"),
                           let chapterIndex = event.chapterIndex,
                           event.chaptersTotal > 0 {
                            self.detailContent.progressLabel.stringValue = L10n.string(
                                "bookDetail.progressChapter",
                                chapterIndex + 1,
                                event.chaptersTotal
                            )
                        } else if event.chaptersTotal > 0 {
                            let percent = Int(event.percent.rounded())
                            self.localConversionProgress = percent
                            self.detailContent.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", percent)
                        }
                    },
                    { [weak self] event in
                        guard let self, self.localConversionGeneration == jobID else { return }
                        let chapter = event.playableChapter
                        if let existing = self.localConversionChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localConversionChapters[existing] = chapter
                        } else {
                            self.localConversionChapters.append(chapter)
                        }
                        self.localConversionChapters.sort { $0.index < $1.index }
                        let percent = min(99, Int(event.progressPercent.rounded()))
                        self.localConversionProgress = percent
                        self.detailContent.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", percent)
                    }
                )
                guard !Task.isCancelled, localConversionGeneration == jobID else { return }
                guard result.jobID == jobID else {
                    throw EmbeddedConverterError.conversionFailed("Conversion returned a different manual job.")
                }
                _ = try finalizeLocalConversion(result)
            } catch {
                guard !Task.isCancelled, localConversionGeneration == jobID else { return }
                localConversionGeneration = nil
                let alert = NSAlert()
                detailContent.recoveryPanel.refresh(bookID: book.id)
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = AppErrorReporter.message(error, context: #function)
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    private func presentListenError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string("bookDetail.listenStart")
        alert.informativeText = AppErrorReporter.message(error, context: #function)
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

    func finalizeLocalConversion(
        _ result: RustConversionCoordinator.Result
    ) throws -> JobSnapshot {
        let snapshot = try result.snapshot()
        library.recordConversion(jobId: result.jobID, for: book.id)
        localConversionGeneration = nil
        localConversionProgress = 100
        detailContent.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", 100)
        detailContent.render(book: book, localConversionProgress: localConversionProgress)
        if let coverage = snapshot.bookAudioCoverageLabel { detailContent.progressLabel.stringValue = coverage }
        return snapshot
    }

    @objc private func tapDownload() {
        if let snapshot = player.snapshot, snapshot.bookTitle == book.resolvedTitle {
            Task {
                await AudiobookDownloads.shared.enqueueAll(snapshot: snapshot, baseURL: settings.resolvedBaseURL)
            }
            return
        }
        guard book.lastJobId != nil else {
            let alert = NSAlert()
            alert.messageText = L10n.string("bookDetail.download")
            alert.informativeText = L10n.string("bookDetail.downloadRequiresConversion")
            alert.addButton(withTitle: L10n.string("common.ok"))
            alert.runModal()
            return
        }
        onShowJobs()
    }

    @objc private func tapLog() {
        guard let jobID = book.lastJobId,
              let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        let url = root.appendingPathComponent("EpubToMp3/RustConversions/\(jobID)/conversion.log")
        presentAsSheet(RustConversionLogViewController(logURL: url))
    }

    func downloadWholeBook() {
        tapDownload()
    }
}
#endif
