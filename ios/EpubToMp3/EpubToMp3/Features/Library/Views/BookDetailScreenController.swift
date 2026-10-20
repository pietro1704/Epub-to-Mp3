#if os(iOS)
import UIKit
import Combine

/// Primary product surface for an opened book: cover, progress, and the
/// three actions the spec calls out — Read, Listen, Download — instead of
/// jumping straight into the chapter reader. The standalone Convert tab
/// remains available as an advanced/diagnostic surface; this screen routes
/// "Listen"/"Download" through the same underlying jobs machinery rather
/// than duplicating it. See `docs/reader-spec-comparison.md` P0 gap #4.
@MainActor
final class BookDetailScreenController: UIViewController {
    private var book: BookEntity
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.Executor
    private let streamingExecutor: RustConversionCoordinator.StreamingExecutor
    private let bookFileOpener: @MainActor (String) async throws -> URL

    private let coverView = UIImageView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let progressLabel = UILabel()
    private let readButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)
    private let logButton = UIButton(type: .system)
    private var manualConversionGeneration: String?
    private var playbackGeneration: String?
    private var playbackControl: ConverterPlaybackControl?
    private var playbackCancellables: Set<AnyCancellable> = []
    private var playbackChapters: [JobSnapshot.Chapter] = []
    private var hasDeliveredPlaybackSegment = false

    init(
        book: BookEntity,
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        conversionExecutor: @escaping RustConversionCoordinator.Executor = RustConversionCoordinator.execute,
        streamingExecutor: @escaping RustConversionCoordinator.StreamingExecutor = RustConversionCoordinator.executeStreaming,
        bookFileOpener: (@MainActor (String) async throws -> URL)? = nil
    ) {
        self.book = book
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.conversionExecutor = conversionExecutor
        self.streamingExecutor = streamingExecutor
        self.bookFileOpener = bookFileOpener ?? { id in
            try await library.openBookFileAsync(id: id)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(book: BookEntity) {
        self.book = book
        render()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureLayout()
        observePlaybackChapterChanges()
        render()
    }

    private func observePlaybackChapterChanges() {
        NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated {
                    guard let self, bookID == nil || bookID == self.book.id else { return }
                    let ownsPlayer = self.player.snapshot?.jobId == self.playbackGeneration
                    self.manualConversionGeneration = nil
                    self.playbackGeneration = nil
                    self.playbackControl?.cancel()
                    self.playbackControl = nil
                    if ownsPlayer { self.player.stop(); self.player.clearConversionState() }
                }
            }
            .store(in: &playbackCancellables)
        player.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let snapshot, let jobID = self.playbackGeneration,
                      snapshot.jobId != jobID else { return }
                self.playbackGeneration = nil
                self.playbackControl?.cancel()
                self.playbackControl = nil
            }
            .store(in: &playbackCancellables)
        player.$activeStreamingChapterIndex
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] chapterIndex in
                guard let self, let control = self.playbackControl else { return }
                control.updatePlaybackWindow(currentChapter: chapterIndex, chaptersAhead: 1)
                _ = control.prioritize(chapterIndex: chapterIndex)
            }
            .store(in: &playbackCancellables)
    }

    private func configureLayout() {
        coverView.contentMode = .scaleAspectFit
        coverView.layer.cornerRadius = 8
        coverView.clipsToBounds = true
        coverView.backgroundColor = .secondarySystemBackground

        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        authorLabel.font = .preferredFont(forTextStyle: .subheadline)
        authorLabel.textColor = .secondaryLabel
        authorLabel.textAlignment = .center

        progressLabel.font = .preferredFont(forTextStyle: .footnote)
        progressLabel.textColor = .secondaryLabel
        progressLabel.textAlignment = .center

        readButton.configuration = .filled()
        readButton.setTitle(L10n.string("bookDetail.read"), for: .normal)
        readButton.addTarget(self, action: #selector(tapRead), for: .touchUpInside)

        listenButton.configuration = .bordered()
        listenButton.accessibilityIdentifier = "bookDetail.listen"
        listenButton.addTarget(self, action: #selector(tapListen), for: .touchUpInside)

        downloadButton.configuration = .bordered()
        downloadButton.accessibilityIdentifier = "bookDetail.download"
        downloadButton.setTitle(L10n.string("bookDetail.download"), for: .normal)
        downloadButton.addTarget(self, action: #selector(tapDownload), for: .touchUpInside)

        logButton.configuration = .bordered()
        logButton.setTitle(L10n.string("conversion.log"), for: .normal)
        logButton.addTarget(self, action: #selector(tapLog), for: .touchUpInside)

        [titleLabel, authorLabel, progressLabel].forEach {
            $0.adjustsFontForContentSizeCategory = true
            $0.numberOfLines = 0
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        [readButton, listenButton, downloadButton, logButton].forEach {
            $0.titleLabel?.numberOfLines = 0
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        let actions = UIStackView(arrangedSubviews: [readButton, listenButton, downloadButton, logButton])
        actions.axis = .vertical
        actions.spacing = 12
        actions.distribution = .fill

        let stack = UIStackView(arrangedSubviews: [coverView, titleLabel, authorLabel, progressLabel, actions])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        IOSScrollableStack.install(stack, in: view)
        NSLayoutConstraint.activate([
            coverView.widthAnchor.constraint(equalToConstant: 160),
            coverView.heightAnchor.constraint(equalToConstant: 220),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            authorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

    }

    private func render() {
        titleLabel.text = book.resolvedTitle
        authorLabel.text = book.author
        authorLabel.isHidden = (book.author ?? "").isEmpty
        coverView.image = book.coverPNG.flatMap(UIImage.init(data:))
        if let entry = ReaderProgressStore.read(bookId: book.id) {
            let percent = Int((entry.offsetFraction * 100).rounded())
            progressLabel.text = L10n.string("bookDetail.progressPercent", percent)
        } else {
            progressLabel.text = L10n.string("bookDetail.notStarted")
        }
        if book.fileType.supportsAudioConversion {
            listenButton.isEnabled = true
            listenButton.setTitle(
                book.lastJobId != nil ? L10n.string("bookDetail.listenResume") : L10n.string("bookDetail.listenStart"),
                for: .normal
            )
        } else {
            // Comics (CBZ/CBR) are read visually — there's no text to
            // narrate without OCR, which is out of scope.
            listenButton.isEnabled = false
            listenButton.setTitle(L10n.string("bookDetail.listenUnavailableComic"), for: .normal)
        }
    }

    /// Reuses the existing reactive overlay instead of instantiating a
    /// second `BookOpenScreenController`: `MainReaderScreenController`
    /// already observes `UserDefaults.didChangeNotification` and shows
    /// itself whenever `ReaderSessionState.currentlyReadingBookID` is set
    /// (see `IOSRootContainerController`) — the exact mechanism the
    /// Library grid used before Book Detail existed.
    @objc private func tapRead() {
        ReaderSessionState.setCurrentlyReading(bookID: book.id)
        navigationController?.popToRootViewController(animated: true)
    }

    @objc private func tapListen() {
        guard playbackGeneration == nil else { return }
        // Reader progress is an array position, whereas local audio artifacts
        // use the EPUB's canonical chapter index. Resolve it once so the
        // playback binding and conversion request agree on the visible chapter.
        let priorityChapterIndex = ReaderPlaybackPriorityChapter.index(bookID: book.id)
        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: book.id,
            chapterIndex: priorityChapterIndex
        )
        let bookID = book.id
        let jobID = UUID().uuidString
        playbackGeneration = jobID
        let conversionOptions = settings.conversionOptions
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.bookFileOpener(bookID)
                guard self.playbackGeneration == jobID else { return }
                try await self.startStreaming(url: url, bookID: bookID, chapterStart: priorityChapterIndex,
                                              jobID: jobID, conversionOptions: conversionOptions)
            } catch {
                guard self.playbackGeneration == jobID else { return }
                self.playbackGeneration = nil
                self.presentListenError(error)
            }
        }
    }

    private func startStreaming(url: URL, bookID: String, chapterStart: Int, jobID: String,
                                conversionOptions: ConversionOptions) async throws {
        playbackControl?.cancel()
        let control = try RustConversionCoordinator.makePlaybackControl()
        control.updatePlaybackWindow(currentChapter: chapterStart, chaptersAhead: 1)
        playbackControl = control
        playbackGeneration = jobID
        playbackChapters.removeAll()
        hasDeliveredPlaybackSegment = false

        let pending = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: book.resolvedTitle,
            bookAuthor: book.author, coverUrl: nil, coverMimeType: nil,
            engine: conversionOptions.engine, voice: conversionOptions.voice, language: conversionOptions.language,
            progressPercent: 0, chaptersTotal: nil, chaptersCompleted: 0,
            chapterProgress: [], outputs: nil, logUrl: nil, error: nil,
            lastActivityAt: Date().timeIntervalSince1970
        )
        if player.positionSeconds > 1 {
            player.pause()
            player.persistResumePoint(force: true)
        }
        player.stop()
        player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
        player.isConverting = true
        player.resume()

        let chunkDelivery = StreamingPlaybackChunkDelivery(player: player)
        do {
            let result = try await streamingExecutor(
                url, jobID, Int32(chapterStart), -1, control,
                conversionOptions,
                { [weak self] event in
                    guard let self, self.playbackGeneration == jobID,
                          let snapshot = self.player.snapshot, snapshot.jobId == jobID else { return }
                    self.player.updateSnapshot(event.updating(snapshot))
                    if event.chaptersTotal > 0 {
                        self.progressLabel.text = L10n.string("bookDetail.progressPercent", Int(event.percent.rounded()))
                    }
                },
                { [weak self] event in
                    guard let self, self.playbackGeneration == jobID,
                          self.player.snapshot?.jobId == jobID else { return }
                    let activeChapter = self.player.activeStreamingChapterIndex ?? chapterStart
                    guard event.chapterIndex >= activeChapter, event.chapterIndex <= activeChapter + 1 else { return }
                    let chapter = event.playableChapter
                    if let index = self.playbackChapters.firstIndex(where: { $0.index == chapter.index }) {
                        self.playbackChapters[index] = chapter
                    } else {
                        self.playbackChapters.append(chapter)
                    }
                    self.playbackChapters.sort { $0.index < $1.index }
                    self.progressLabel.text = L10n.string("bookDetail.progressPercent", Int(event.progressPercent.rounded()))
                    self.player.updateSnapshot(event.snapshot(chapters: self.playbackChapters, preserving: self.player.snapshot))
                },
                { [weak self] chapterIndex, chunkIndex, data in
                    guard let self else { return false }
                    return chunkDelivery.enqueue(
                        data, chapterIndex: chapterIndex, chunkIndex: chunkIndex,
                        isCurrent: { [weak self] in
                            guard let self, let control = self.playbackControl else { return false }
                            let activeChapter = self.player.activeStreamingChapterIndex ?? chapterStart
                            return self.playbackGeneration == jobID
                                && self.player.snapshot?.jobId == jobID
                                && control.contains(chapterIndex: chapterIndex)
                                && chapterIndex >= activeChapter && chapterIndex <= activeChapter + 1
                        },
                        onAccepted: { [weak self] in
                            guard let self, self.playbackGeneration == jobID,
                                  !self.hasDeliveredPlaybackSegment else { return }
                            self.hasDeliveredPlaybackSegment = true
                            self.playerPresentation.showFullPlayer()
                        }
                    )
                }
            )
            guard playbackGeneration == jobID, player.snapshot?.jobId == jobID else { return }
            let snapshot = try result.snapshot()
            let indices = snapshot.playableChapters.map(\.index)
            guard result.jobID == jobID, snapshot.jobId == jobID,
                  indices.first == chapterStart, indices == indices.sorted(), Set(indices).count == indices.count else {
                throw EmbeddedConverterError.conversionFailed("Conversion did not preserve the requested chapter order.")
            }
            library.recordConversion(jobId: result.jobID, for: bookID)
            guard playbackGeneration == jobID, player.snapshot?.jobId == jobID else { return }
            book.lastJobId = result.jobID
            playbackGeneration = nil
            playbackControl = nil
            player.finishStreaming(snapshot: snapshot)
        } catch {
            guard playbackGeneration == jobID else { throw error }
            playbackGeneration = nil
            playbackControl?.cancel()
            playbackControl = nil
            if let current = player.snapshot, current.jobId == jobID {
                player.finishStreaming(snapshot: terminalSnapshot(from: current, state: "failed", error: error.localizedDescription))
            }
            throw error
        }
    }

    private func presentListenError(_ error: Error) {
        guard isViewLoaded, view.window != nil else { return }
        let alert = UIAlertController(
            title: L10n.string("bookDetail.listenStart"),
            message: AppErrorReporter.message(error, context: #function),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        present(alert, animated: true)
    }

    private func terminalSnapshot(from snapshot: JobSnapshot, state: String, error: String) -> JobSnapshot {
        JobSnapshot(
            jobId: snapshot.jobId, state: state, bookTitle: snapshot.bookTitle,
            bookAuthor: snapshot.bookAuthor, coverUrl: snapshot.coverUrl,
            coverMimeType: snapshot.coverMimeType, engine: snapshot.engine,
            voice: snapshot.voice, language: snapshot.language,
            progressPercent: snapshot.progressPercent, chaptersTotal: snapshot.chaptersTotal,
            chaptersCompleted: snapshot.chaptersCompleted, chapterProgress: snapshot.chapterProgress,
            outputs: snapshot.outputs, logUrl: snapshot.logUrl, error: error,
            lastActivityAt: Date().timeIntervalSince1970
        )
    }

    @objc private func tapLog() {
        guard let jobID = book.lastJobId,
              let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        let url = root.appendingPathComponent("EpubToMp3/RustConversions/\(jobID)/conversion.log")
        navigationController?.pushViewController(RustConversionLogViewController(logURL: url), animated: true)
    }

    @objc private func tapDownload() {
        guard manualConversionGeneration == nil else { return }
        let jobID = UUID().uuidString
        manualConversionGeneration = jobID
        let bookID = book.id
        let conversionOptions = settings.conversionOptions
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.manualConversionGeneration == jobID { self.manualConversionGeneration = nil }
            }
            if let url = try? await self.bookFileOpener(bookID) {
                guard self.manualConversionGeneration == jobID else { return }
                do {
                    let result = try await self.conversionExecutor(
                        url, jobID, -1, -1,
                        conversionOptions,
                        nil, nil
                    )
                    guard self.manualConversionGeneration == jobID else { return }
                    guard result.jobID == jobID else {
                        throw EmbeddedConverterError.conversionFailed("Conversion returned a different manual job.")
                    }
                    _ = try result.snapshot()
                    if self.book.id == bookID { self.book.lastJobId = result.jobID }
                    self.library.recordConversion(jobId: result.jobID, for: bookID)
                    self.render()
                    return
                } catch {
                    guard self.manualConversionGeneration == jobID else { return }
                    let alert = UIAlertController(
                        title: L10n.string("bookDetail.download"),
                        message: AppErrorReporter.message(error, context: #function),
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                    self.present(alert, animated: true)
                }
                return
            }
            guard self.manualConversionGeneration == jobID else { return }
            self.downloadExistingJob()
        }
    }

    private func downloadExistingJob() {
        guard let jobId = book.lastJobId else {
            let alert = UIAlertController(
                title: L10n.string("bookDetail.download"),
                message: L10n.string("bookDetail.downloadRequiresConversion"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
            return
        }
        if let snapshot = player.snapshot, snapshot.jobId == jobId {
            Task {
                await DownloadManager.shared.enqueueAll(
                    snapshot: snapshot,
                    baseURL: settings.resolvedBaseURL
                )
            }
            return
        }
        navigationController?.pushViewController(
            JobDetailScreenController(
                jobId: jobId, settings: settings, library: library, player: player, playbackClock: player.playbackClock
            ),
            animated: true
        )
    }

    /// Entry point used by the library context menu. It intentionally reuses
    /// the existing Download/Conversion flow rather than creating a second
    /// backend or a library-specific download path.
    func downloadWholeBook() {
        tapDownload()
    }
}
#endif
