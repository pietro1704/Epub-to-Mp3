#if os(macOS)
import AppKit

@MainActor
final class MacBookDetailContent: NSView {
    private let coverView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let authorLabel = NSTextField(labelWithString: "")
    let progressLabel = NSTextField(labelWithString: "")
    let readButton = NSButton()
    let listenButton = NSButton()
    let convertButton = NSButton()
    let downloadButton = NSButton()
    let logButton = NSButton()
    let pronunciationButton = NSButton()
    let recoveryPanel = BookConversionRecoveryPanel()

    init() {
        super.init(frame: .zero)
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

        listenButton.bezelStyle = .rounded

        convertButton.title = L10n.string("convert.title")
        convertButton.bezelStyle = .rounded
        convertButton.setAccessibilityIdentifier("bookDetail.convert")

        downloadButton.title = L10n.string("bookDetail.download")
        downloadButton.bezelStyle = .rounded

        logButton.title = L10n.string("conversion.log")
        logButton.bezelStyle = .rounded

        [titleLabel, authorLabel, progressLabel].forEach {
            $0.maximumNumberOfLines = 0
            $0.lineBreakMode = .byWordWrapping
            $0.cell?.wraps = true
            $0.cell?.isScrollable = false
        }

        pronunciationButton.title = L10n.string("pronunciation.title")
        pronunciationButton.bezelStyle = .rounded
        pronunciationButton.setAccessibilityIdentifier("bookDetail.pronunciation")
        let actions = NSStackView(views: [readButton, listenButton, convertButton, downloadButton, pronunciationButton, logButton])
        actions.orientation = .vertical
        actions.spacing = 12
        actions.distribution = .fill

        let stack = NSStackView(views: [coverView, titleLabel, authorLabel, progressLabel, recoveryPanel, actions])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        MacScrollableStack.install(stack, in: self, maximumWidth: 480)
        NSLayoutConstraint.activate([
            coverView.widthAnchor.constraint(equalToConstant: 180),
            coverView.heightAnchor.constraint(equalToConstant: 240),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            authorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

    }

    func render(book: BookEntity, localConversionProgress: Int?) {
        recoveryPanel.refresh(bookID: book.id)
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

}
#endif
