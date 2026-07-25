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
    private let onRead: (String) -> Void
    private let onShowJobs: () -> Void

    private let coverView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private let readButton = NSButton()
    private let listenButton = NSButton()
    private let downloadButton = NSButton()

    init(
        book: BookEntity,
        onRead: @escaping (String) -> Void,
        onShowJobs: @escaping () -> Void
    ) {
        self.book = book
        self.onRead = onRead
        self.onShowJobs = onShowJobs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        listenButton.title = book.lastJobId != nil
            ? L10n.string("bookDetail.listenResume")
            : L10n.string("bookDetail.listenStart")
    }

    @objc private func tapRead() {
        onRead(book.id)
    }

    /// macOS has no per-book-scoped conversion/job screen yet (unlike iOS's
    /// `ConvertScreenController(preselectedFileURL:)` /
    /// `JobDetailScreenController(jobId:)`) — `MacJobsListViewController`
    /// takes no book context at all. Rather than fake a deep link that
    /// goes nowhere, both actions route to the Jobs sidebar, where the
    /// conversion/download UI actually lives today.
    @objc private func tapListen() {
        onShowJobs()
    }

    @objc private func tapDownload() {
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
