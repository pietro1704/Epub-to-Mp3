#if os(iOS)
import UIKit

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

    private let coverView = UIImageView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let progressLabel = UILabel()
    private let readButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)
    private let downloadButton = UIButton(type: .system)

    init(
        book: BookEntity,
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer
    ) {
        self.book = book
        self.library = library
        self.settings = settings
        self.player = player
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
        render()
    }

    private func configureLayout() {
        coverView.contentMode = .scaleAspectFit
        coverView.layer.cornerRadius = 8
        coverView.clipsToBounds = true
        coverView.backgroundColor = .secondarySystemBackground

        titleLabel.font = .preferredFont(forTextStyle: .title1)
        titleLabel.numberOfLines = 2
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
        listenButton.addTarget(self, action: #selector(tapListen), for: .touchUpInside)

        downloadButton.configuration = .bordered()
        downloadButton.setTitle(L10n.string("bookDetail.download"), for: .normal)
        downloadButton.addTarget(self, action: #selector(tapDownload), for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [readButton, listenButton, downloadButton])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [coverView, titleLabel, authorLabel, progressLabel, actions])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            coverView.widthAnchor.constraint(equalToConstant: 160),
            coverView.heightAnchor.constraint(equalToConstant: 220),
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
        if let jobId = book.lastJobId {
            navigationController?.pushViewController(
                JobDetailScreenController(
                    jobId: jobId, settings: settings, library: library, player: player, playbackClock: player.playbackClock
                ),
                animated: true
            )
            return
        }
        guard let url = try? library.openBookFile(id: book.id) else { return }
        navigationController?.pushViewController(
            ConvertScreenController(
                settings: settings, library: library, player: player,
                playbackClock: player.playbackClock, preselectedFileURL: url
            ),
            animated: true
        )
    }

    @objc private func tapDownload() {
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
        navigationController?.pushViewController(
            JobDetailScreenController(
                jobId: jobId, settings: settings, library: library, player: player, playbackClock: player.playbackClock
            ),
            animated: true
        )
    }
}
#endif
