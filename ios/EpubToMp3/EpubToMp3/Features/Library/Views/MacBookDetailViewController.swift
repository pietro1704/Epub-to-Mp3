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
    private let streamingExecutor: RustConversionCoordinator.StreamingExecutor
    private let onRead: (String) -> Void
    private let onShowJobs: () -> Void
    private let jobViewModel = JobDetailViewModel()
    private var playbackGeneration: UUID?
    private var streamDeliveryGeneration: UUID?
    private var autoPlayStream = false
    private var localConversionGeneration: String?
    private var localPlaybackGeneration: String?
    private var localConversionProgress: Int?
    private var localConversionChapters: [JobSnapshot.Chapter] = []
    private var localPlaybackChapters: [JobSnapshot.Chapter] = []
    private var localPlaybackControl: ConverterPlaybackControl?
    private var hasDeliveredLocalPlaybackSegment = false
    private var playbackCancellables: Set<AnyCancellable> = []

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
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureStreamingCallbacks()
        observeLocalPlaybackChapterChanges()
        configureLayout()
        render()
    }

    private func observeLocalPlaybackChapterChanges() {
        NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated {
                    guard let self, bookID == nil || bookID == self.book.id else { return }
                    let ownsPlayer = self.player.snapshot?.jobId == self.localPlaybackGeneration
                    self.localConversionGeneration = nil
                    self.localConversionProgress = nil
                    self.localConversionChapters.removeAll()
                    self.progressLabel.stringValue = ""
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
        titleLabel.lineBreakMode = .byWordWrapping

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

        [titleLabel, authorLabel, progressLabel].forEach {
            $0.maximumNumberOfLines = 0
            $0.lineBreakMode = .byWordWrapping
            $0.cell?.wraps = true
            $0.cell?.isScrollable = false
        }

        let actions = NSStackView(views: [readButton, listenButton, convertButton, downloadButton, logButton])
        actions.orientation = .vertical
        actions.spacing = 12
        actions.distribution = .fill

        let stack = NSStackView(views: [coverView, titleLabel, authorLabel, progressLabel, actions])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        MacScrollableStack.install(stack, in: view, maximumWidth: 480)
        NSLayoutConstraint.activate([
            coverView.widthAnchor.constraint(equalToConstant: 180),
            coverView.heightAnchor.constraint(equalToConstant: 240),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            authorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
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

    @objc private func tapConvert() {
        let alert = NSAlert()
        alert.messageText = L10n.string("convert.title")
        alert.addButton(withTitle: L10n.string("convert.title"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 40, width: 300, height: 28))
        choice.addItems(withTitles: [L10n.string("convert.usePreferences")] + AudioEnginePreference.supportedPreferences.map(\.displayName))
        choice.setAccessibilityLabel(L10n.string("settings.audioEngineChoice"))
        choice.setAccessibilityIdentifier("convert.tts.primary")
        choice.target = self
        choice.action = #selector(manualConversionEngineChanged(_:))
        let secondary = NSButton(checkboxWithTitle: L10n.string("convert.allowSecondary"), target: nil, action: nil)
        secondary.frame = NSRect(x: 0, y: 0, width: 300, height: 28)
        secondary.setAccessibilityIdentifier("convert.tts.useSecondary")
        secondary.state = settings.secondaryAudioEngine == nil ? .off : .on
        secondary.isEnabled = false
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        accessory.addSubview(choice)
        accessory.addSubview(secondary)
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var options = settings.conversionOptions
        if choice.indexOfSelectedItem > 0 {
            let engine = AudioEnginePreference.supportedPreferences[choice.indexOfSelectedItem - 1]
            options = .selectedEngine(engine, modelsRoot: AppSettings.ttsModelsRoot())
            let distinctSecondary = settings.ttsPreferences.secondary.flatMap { $0 == .selected(engine) ? nil : $0 }
            options.ttsPreferences = TtsPreferences(primary: .selected(engine),
                secondary: secondary.state == .on ? distinctSecondary : nil,
                allowOnlineFallback: secondary.state == .on && distinctSecondary != nil && settings.allowOnlineAudioFallback,
                policyVersion: secondary.state == .on ? settings.ttsPreferences.policyVersion : nil)
            options.modelsRoot = AppSettings.ttsModelsRoot()?.path
            options.espeakDataDirectory = Bundle.main.resourceURL?.path
        }
        convertWholeBook(options: options)
    }

    @objc private func manualConversionEngineChanged(_ sender: NSPopUpButton) {
        guard let secondary = sender.superview?.subviews.compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityIdentifier() == "convert.tts.useSecondary" }) else { return }
        let selected = sender.indexOfSelectedItem > 0
            ? TtsSelection.selected(AudioEnginePreference.supportedPreferences[sender.indexOfSelectedItem - 1]) : nil
        secondary.isEnabled = selected != nil && settings.ttsPreferences.secondary.map { $0 != selected } == true
        secondary.state = sender.indexOfSelectedItem == 0 && settings.secondaryAudioEngine != nil ? .on : .off
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
        progressLabel.stringValue = L10n.string("bookDetail.progressPercent", 0)

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await conversionExecutor(
                    url, jobID, -1, -1,
                    options,
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
                        let chapter = event.playableChapter
                        if let existing = self.localConversionChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localConversionChapters[existing] = chapter
                        } else {
                            self.localConversionChapters.append(chapter)
                        }
                        self.localConversionChapters.sort { $0.index < $1.index }
                        let percent = Int(event.progressPercent.rounded())
                        self.localConversionProgress = percent
                        self.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", percent)
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
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    private func startRustStreaming(url: URL, jobID: String) {
        guard localPlaybackGeneration == jobID else { return }
        localPlaybackControl?.cancel()
        let chapterStart = Int32(exactly: ReaderPlaybackPriorityChapter.index(bookID: book.id)) ?? 0
        do {
            let control = try RustConversionCoordinator.makePlaybackControl()
            control.updatePlaybackWindow(currentChapter: Int(chapterStart), chaptersAhead: 1)
            localPlaybackControl = control
            localPlaybackGeneration = jobID
            localConversionProgress = 0
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
                lastActivityAt: Date().timeIntervalSince1970
            )
            player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
            player.isConverting = true
            player.resume()
        } catch {
            guard localPlaybackGeneration == jobID else { return }
            localPlaybackGeneration = nil
            presentListenError(error)
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
                            self.localConversionProgress = percent
                            self.progressLabel.stringValue = L10n.string("bookDetail.progressPercent", percent)
                        }
                    },
                    { [weak self] event in
                        guard let self, self.localPlaybackGeneration == jobID,
                              self.player.snapshot?.jobId == jobID else { return }
                        let activeChapter = self.player.activeStreamingChapterIndex ?? Int(chapterStart)
                        guard event.chapterIndex >= activeChapter,
                              event.chapterIndex <= activeChapter + 1 else { return }
                        let chapter = event.playableChapter
                        if let existing = self.localPlaybackChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localPlaybackChapters[existing] = chapter
                        } else {
                            self.localPlaybackChapters.append(chapter)
                        }
                        self.localPlaybackChapters.sort { $0.index < $1.index }
                        self.localConversionProgress = Int(event.progressPercent.rounded())
                        self.progressLabel.stringValue = L10n.string(
                            "bookDetail.progressPercent", self.localConversionProgress ?? 0
                        )
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
                                let activeChapter = self.player.activeStreamingChapterIndex ?? Int(chapterStart)
                                return self.localPlaybackGeneration == jobID
                                    && self.player.snapshot?.jobId == jobID
                                    && control.contains(chapterIndex: chapterIndex)
                                    && chapterIndex >= activeChapter
                                    && chapterIndex <= activeChapter + 1
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
                localConversionProgress = 100
                progressLabel.stringValue = L10n.string("bookDetail.progressPercent", 100)
                player.finishStreaming(snapshot: snapshot)
                playerPresentation.showFullPlayer()
            } catch {
                guard localPlaybackGeneration == jobID else { return }
                localPlaybackGeneration = nil
                localPlaybackControl?.cancel()
                localPlaybackControl = nil
                if let current = player.snapshot, current.jobId == jobID {
                    player.finishStreaming(snapshot: terminalSnapshot(from: current, state: "failed", error: error.localizedDescription))
                }
                presentListenError(error)
            }
        }
    }

    private func presentListenError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L10n.string("bookDetail.listenStart")
        alert.informativeText = error.localizedDescription
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
