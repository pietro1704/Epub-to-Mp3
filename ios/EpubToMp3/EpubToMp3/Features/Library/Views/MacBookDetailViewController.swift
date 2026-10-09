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
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let conversionExecutor: RustConversionCoordinator.Executor
    private let onRead: (String) -> Void
    private let onShowJobs: () -> Void
    private let jobViewModel = JobDetailViewModel()
    private var playbackGeneration: UUID?
    private var streamDeliveryGeneration: UUID?
    private var autoPlayStream = false
    private var localConversionGeneration: String?
    private var localConversionProgress: Int?
    private var localStreamChapters: [JobSnapshot.Chapter] = []

    private let coverView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let readButton = NSButton()
    private let listenButton = NSButton()
    private let convertButton = NSButton()
    private let downloadButton = NSButton()
    private let logButton = NSButton()

    init(
        book: BookEntity,
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        onRead: @escaping (String) -> Void,
        onShowJobs: @escaping () -> Void,
        conversionExecutor: @escaping RustConversionCoordinator.Executor = RustConversionCoordinator.execute
    ) {
        self.book = book
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.onRead = onRead
        self.onShowJobs = onShowJobs
        self.conversionExecutor = conversionExecutor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }



    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureStreamingCallbacks()
        configureLayout()
        render()
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

    private func configureLayout() {
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 8
        coverView.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        authorLabel.font = .systemFont(ofSize: 13)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.alignment = .center

        progressLabel.font = .systemFont(ofSize: 12)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .center
        progressLabel.setAccessibilityIdentifier("bookDetail.progress")

        readButton.title = L10n.string("bookDetail.read")
        readButton.bezelStyle = .rounded
        readButton.target = self
        readButton.action = #selector(tapRead)

        listenButton.bezelStyle = .rounded
        listenButton.target = self
        listenButton.action = #selector(tapListen)

        convertButton.title = L10n.string("convert.title")
        convertButton.bezelStyle = .rounded
        convertButton.setAccessibilityIdentifier("bookDetail.convert")
        convertButton.target = self
        convertButton.action = #selector(tapConvert)

        downloadButton.title = L10n.string("bookDetail.download")
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(tapDownload)

        logButton.title = L10n.string("conversion.log")
        logButton.bezelStyle = .rounded
        logButton.target = self
        logButton.action = #selector(tapLog)

        let actions = NSStackView(views: [readButton, listenButton, convertButton, downloadButton, logButton])
        actions.orientation = .horizontal
        actions.spacing = 12
        actions.distribution = .fillEqually

        let stack = NSStackView(views: [coverView, titleLabel, authorLabel, progressLabel, actions])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 180),
            coverView.heightAnchor.constraint(equalToConstant: 240),
            actions.widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    private func render() {
        titleLabel.stringValue = book.resolvedTitle
        authorLabel.stringValue = book.author ?? ""
        authorLabel.isHidden = (book.author ?? "").isEmpty
        coverView.image = book.coverPNG.flatMap(NSImage.init(data:))
        if let localConversionProgress {
            progressLabel.stringValue = L10n.string("bookDetail.progressPercent", localConversionProgress)
        } else if let entry = ReaderProgressStore.read(bookId: book.id) {
            let percent = Int((entry.offsetFraction * 100).rounded())
            progressLabel.stringValue = L10n.string("bookDetail.progressPercent", percent)
        } else {
            progressLabel.stringValue = L10n.string("bookDetail.notStarted")
        }
        if book.fileType.supportsAudioConversion {
            listenButton.isEnabled = true
            listenButton.title = book.lastJobId != nil
                ? L10n.string("bookDetail.listenResume")
                : L10n.string("bookDetail.listenStart")
        } else {
            // Comics (CBZ/CBR) are read visually — there's no text to
            // narrate without OCR, which is out of scope.
            listenButton.isEnabled = false
            listenButton.title = L10n.string("bookDetail.listenUnavailableComic")
        }
    }

    @objc private func tapRead() {
        onRead(book.id)
    }

    /// macOS starts conversion directly from Book Detail. Embedded conversion
    /// stays local by default; server-only formats and the explicit remote
    /// provider use the same API/SSE contract as iOS.
    @objc private func tapListen() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                guard !Task.isCancelled else { return }
                startRustConversion(url: url, autoPlay: true)
            } catch {
                guard !Task.isCancelled else { return }
                onShowJobs()
            }
        }
    }

    @objc private func tapConvert() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                startRustConversion(url: url, autoPlay: false)
            } catch {
                onShowJobs()
            }
        }
    }

    func convertWholeBook() {
        tapConvert()
    }

    private func startRustConversion(url: URL, autoPlay: Bool) {
        let bookID = self.book.id
        let jobID = UUID().uuidString
        localConversionGeneration = jobID
        localConversionProgress = 0
        localStreamChapters.removeAll()
        progressLabel.stringValue = L10n.string("bookDetail.progressPercent", 0)
        if autoPlay {
            let pending = JobSnapshot(
                jobId: jobID,
                state: "running",
                bookTitle: book.resolvedTitle,
                bookAuthor: book.author,
                coverUrl: nil,
                coverMimeType: nil,
                engine: "edge",
                voice: nil,
                language: nil,
                progressPercent: 0,
                chaptersTotal: nil,
                chaptersCompleted: 0,
                chapterProgress: [],
                outputs: nil,
                logUrl: nil,
                error: nil,
                lastActivityAt: Date().timeIntervalSince1970
            )
            player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
            player.isConverting = true
            player.resume()
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let chapterStart = autoPlay
                    ? Int32(exactly: ReaderPlaybackPriorityChapter.index(bookID: bookID)) ?? 0
                    : -1
                let result = try await conversionExecutor(
                    url, jobID, chapterStart, -1,
                    { [weak self] event in
                        guard let self, self.localConversionGeneration == jobID else { return }
                        if event.message.hasPrefix("converting chapter"),
                           let chapterIndex = event.chapterIndex,
                           event.chaptersTotal > 0 {
                            self.progressLabel.stringValue = L10n.string(
                                "bookDetail.progressChapter",
                                chapterIndex + 1,
                                event.chaptersTotal
                            )
                        } else if event.chaptersTotal > 0 {
                            let percent = Int(event.percent.rounded())
                            self.localConversionProgress = percent
                            self.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", percent)
                        }
                    },
                    { [weak self] event in
                        guard let self, self.localConversionGeneration == jobID else { return }
                        let firstPlayableChapter = self.localStreamChapters.isEmpty
                        let chapter = event.playableChapter
                        if let existing = self.localStreamChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localStreamChapters[existing] = chapter
                        } else {
                            self.localStreamChapters.append(chapter)
                        }
                        self.localStreamChapters.sort { $0.index < $1.index }
                        let percent = Int(event.progressPercent.rounded())
                        self.localConversionProgress = percent
                        self.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", percent)
                        if autoPlay {
                            self.player.updateSnapshot(
                                event.snapshot(chapters: self.localStreamChapters)
                            )
                            if firstPlayableChapter {
                                self.playerPresentation.showFullPlayer()
                            }
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                let snapshot = try finalizeLocalConversion(result)
                if autoPlay {
                    player.finishStreaming(snapshot: snapshot)
                }
            } catch {
                guard !Task.isCancelled else { return }
                localConversionGeneration = nil
                if autoPlay, let current = player.snapshot, current.jobId == jobID {
                    player.finishStreaming(snapshot: terminalSnapshot(
                        from: current,
                        state: "failed",
                        error: error.localizedDescription
                    ))
                }
                let alert = NSAlert()
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    func finalizeLocalConversion(
        _ result: RustConversionCoordinator.Result
    ) throws -> JobSnapshot {
        let snapshot = try result.snapshot()
        library.recordConversion(jobId: result.jobID, for: book.id)
        localConversionGeneration = nil
        localConversionProgress = 100
        progressLabel.stringValue = L10n.string("bookDetail.progressPercent", 100)
        render()
        return snapshot
    }

    private func terminalSnapshot(from snapshot: JobSnapshot, state: String, error: String) -> JobSnapshot {
        JobSnapshot(
            jobId: snapshot.jobId,
            state: state,
            bookTitle: snapshot.bookTitle,
            bookAuthor: snapshot.bookAuthor,
            coverUrl: snapshot.coverUrl,
            coverMimeType: snapshot.coverMimeType,
            engine: snapshot.engine,
            voice: snapshot.voice,
            language: snapshot.language,
            progressPercent: snapshot.progressPercent,
            chaptersTotal: snapshot.chaptersTotal,
            chaptersCompleted: snapshot.chaptersCompleted,
            chapterProgress: snapshot.chapterProgress,
            outputs: snapshot.outputs,
            logUrl: snapshot.logUrl,
            error: error,
            lastActivityAt: Date().timeIntervalSince1970
        )
    }

    @objc private func tapDownload() {
        if let snapshot = player.snapshot, snapshot.bookTitle == book.resolvedTitle {
            Task {
                await DownloadManager.shared.enqueueAll(snapshot: snapshot, baseURL: settings.resolvedBaseURL)
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
