#if os(macOS)
import AppKit

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
    private let onRead: (String) -> Void
    private let onShowJobs: () -> Void
    private var remoteStreamTask: Task<Void, Never>?

    private let coverView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let readButton = NSButton()
    private let listenButton = NSButton()
    private let downloadButton = NSButton()

    init(
        book: BookEntity,
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        onRead: @escaping (String) -> Void,
        onShowJobs: @escaping () -> Void
    ) {
        self.book = book
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.onRead = onRead
        self.onShowJobs = onShowJobs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        remoteStreamTask?.cancel()
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureLayout()
        render()
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

        readButton.title = L10n.string("bookDetail.read")
        readButton.bezelStyle = .rounded
        readButton.target = self
        readButton.action = #selector(tapRead)

        listenButton.bezelStyle = .rounded
        listenButton.target = self
        listenButton.action = #selector(tapListen)

        downloadButton.title = L10n.string("bookDetail.download")
        downloadButton.bezelStyle = .rounded
        downloadButton.target = self
        downloadButton.action = #selector(tapDownload)

        let actions = NSStackView(views: [readButton, listenButton, downloadButton])
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
        if let entry = ReaderProgressStore.read(bookId: book.id) {
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
        if settings.useEmbeddedRuntime && !book.fileType.requiresServerConversion {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let priorityChapterIndex = ReaderProgressStore.read(bookId: self.book.id)?.chapterIndex ?? 0
                    if let localSnapshot = await EmbeddedConversionCoordinator.resumeLocalPlaybackIfAvailable(
                        bookID: self.book.id,
                        priorityChapterIndices: [priorityChapterIndex],
                        player: self.player
                    ) {
                        self.playerPresentation.showFullPlayer()
                        if localSnapshot.state == "finished" {
                            self.library.recordConversion(jobId: localSnapshot.jobId, for: self.book.id)
                            return
                        }
                        let url = try await self.library.openBookFileAsync(id: self.book.id)
                        let snapshot = try await EmbeddedConversionCoordinator.continuePartialLocalPlayback(
                            bookURL: url,
                            bookID: self.book.id,
                            priorityChapterIndices: [priorityChapterIndex],
                            player: self.player
                        )
                        self.library.recordConversion(jobId: snapshot.jobId, for: self.book.id)
                        return
                    }

                    let url = try await self.library.openBookFileAsync(id: self.book.id)
                    let snapshot = try await EmbeddedConversionCoordinator.stream(
                        bookURL: url,
                        bookID: book.id,
                        player: self.player,
                        onStreamingStarted: { [weak self] in
                            self?.playerPresentation.showFullPlayer()
                        }
                    )
                    self.library.recordConversion(jobId: snapshot.jobId, for: self.book.id)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = L10n.string("bookDetail.listenStart")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: L10n.string("common.ok"))
                    alert.runModal()
                }
            }
            return
        }
        guard let url = try? library.openBookFile(id: book.id) else {
            onShowJobs()
            return
        }
        startRemoteConversion(url: url)
    }

    private func startRemoteConversion(url: URL) {
        guard let baseURL = settings.resolvedBaseURL else {
            let alert = NSAlert()
            alert.messageText = L10n.string("bookDetail.listenStart")
            alert.informativeText = APIError.invalidBaseURL.localizedDescription
            alert.addButton(withTitle: L10n.string("common.ok"))
            alert.runModal()
            return
        }
        remoteStreamTask?.cancel()
        let player = self.player
        let presentation = self.playerPresentation
        let library = self.library
        let bookID = self.book.id
        remoteStreamTask = Task {
            do {
                let client = APIClient(baseURL: baseURL)
                let response = try await client.submitConversion(
                    localPath: url,
                    options: APIClient.ConvertOptions()
                )
                library.recordConversion(jobId: response.jobId, for: bookID)
                let initial = try await client.fetchJob(id: response.jobId)
                guard !Task.isCancelled else { return }
                player.backendBaseURL = baseURL
                player.play(snapshot: initial)
                presentation.showFullPlayer()
                for try await event in client.eventStream(jobId: response.jobId) {
                    guard !Task.isCancelled else { return }
                    if let snapshot = APIClient.decodeSnapshot(from: event.rawPayload) {
                        player.updateSnapshot(snapshot)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                let alert = NSAlert()
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
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
}
#endif
