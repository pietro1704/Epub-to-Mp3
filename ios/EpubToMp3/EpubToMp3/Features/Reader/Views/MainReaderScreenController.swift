#if os(iOS)
import Combine
import UIKit

@MainActor
final class MainReaderScreenController: UIViewController {
    private var library: LibraryStore
    private var settings: AppSettings
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore
    private var onBrowseLibrary: (() -> Void)?
    var onReaderChromeVisibilityChanged: ((Bool) -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var readerController: BookOpenScreenController?
    private var readerBookID: String?
    /// Mirrors `BookOpenScreenController.onLoadStateChanged` so `render()`
    /// can keep "Ouvir" hidden while the book's content is still loading.
    private var isReaderLoading = false

    private let emptyStateStack = UIStackView()
    private let emptyTitleLabel = UILabel()
    private let emptyDescriptionLabel = UILabel()
    private let browseButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)
    private let readerNavigationBar = UINavigationBar()
    private let readerNavigationItem = UINavigationItem()

    private var currentBook: BookEntity? {
        guard let id = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              !id.isEmpty else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    init(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore,
        onBrowseLibrary: (() -> Void)?
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        self.onBrowseLibrary = onBrowseLibrary
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureReaderNavigationBar()
        configureEmptyState()
        configureListenButton()
        bind()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tabBarController?.tabBar.isHidden = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || navigationController?.topViewController !== self {
            tabBarController?.tabBar.isHidden = false
        }
    }

    func update(
        library: LibraryStore,
        settings: AppSettings,
        onBrowseLibrary: (() -> Void)?
    ) {
        self.library = library
        self.settings = settings
        self.onBrowseLibrary = onBrowseLibrary
        render()
    }

    private func bind() {
        library.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.autoClearMissingBookIfNeeded()
                self?.render()
            }
            .store(in: &cancellables)
    }

    private func configureEmptyState() {
        emptyStateStack.axis = .vertical
        emptyStateStack.spacing = 20
        emptyStateStack.alignment = .center
        emptyStateStack.translatesAutoresizingMaskIntoConstraints = false

        emptyTitleLabel.font = .preferredFont(forTextStyle: .title2)
        emptyTitleLabel.numberOfLines = 0
        emptyTitleLabel.textAlignment = .center
        emptyTitleLabel.text = L10n.string("mainReader.pickBook")

        emptyDescriptionLabel.font = .preferredFont(forTextStyle: .body)
        emptyDescriptionLabel.textColor = .secondaryLabel
        emptyDescriptionLabel.numberOfLines = 0
        emptyDescriptionLabel.textAlignment = .center
        emptyDescriptionLabel.text = L10n.string("mainReader.pickBookDescription")

        var browseConfig = UIButton.Configuration.filled()
        browseConfig.image = UIImage(systemName: "books.vertical")
        browseConfig.imagePadding = 8
        browseConfig.title = L10n.string("mainReader.browseLibrary")
        browseButton.configuration = browseConfig
        browseButton.addTarget(self, action: #selector(browseLibraryTapped), for: .touchUpInside)
        browseButton.accessibilityIdentifier = "mainReader.browseLibrary"

        [emptyTitleLabel, emptyDescriptionLabel, browseButton].forEach { emptyStateStack.addArrangedSubview($0) }
        view.addSubview(emptyStateStack)
        NSLayoutConstraint.activate([
            emptyStateStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            emptyStateStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            emptyStateStack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

    }

    private func configureListenButton() {
        // Playback is controlled exclusively from the persistent mini-player.
        // A second "Listen" button here duplicated the control and pushed the
        // reader content into an inconsistent layout while a book was loading.
        listenButton.isHidden = true
        listenButton.translatesAutoresizingMaskIntoConstraints = false
        listenButton.accessibilityIdentifier = "mainReader.listen"
        listenButton.addTarget(self, action: #selector(listenTapped), for: .touchUpInside)
    }

    private func configureReaderNavigationBar() {
        readerNavigationBar.translatesAutoresizingMaskIntoConstraints = false
        readerNavigationBar.isTranslucent = true
        readerNavigationBar.prefersLargeTitles = false
        readerNavigationBar.items = [readerNavigationItem]

        let closeItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(closeReaderTapped)
        )
        closeItem.accessibilityLabel = L10n.string("common.back")
        closeItem.accessibilityIdentifier = "reader.close"
        readerNavigationItem.leftBarButtonItem = closeItem

        let repickButton = UIButton(type: .system)
        repickButton.setImage(UIImage(systemName: "book.closed"), for: .normal)
        repickButton.accessibilityLabel = L10n.string("reader.repick")
        repickButton.accessibilityIdentifier = "reader.repick"
        repickButton.addTarget(self, action: #selector(repickBookTapped), for: .touchUpInside)
        repickButton.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        repickButton.isHidden = true
        readerNavigationItem.rightBarButtonItem = UIBarButtonItem(customView: repickButton)

        view.addSubview(readerNavigationBar)
        NSLayoutConstraint.activate([
            readerNavigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerNavigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerNavigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    private func render() {
        if let book = currentBook {
            showBook(book)
        } else {
            showEmptyState()
        }
        // Visible once a book is loaded (never for a never-converted book,
        // tapping it starts conversion in the background — mirrors the
        // macOS reader's "Play inicia a conversão/reprodução do livro").
        // Hidden while `BookOpenScreenController` is still parsing so the
        // open screen only ever shows cover+spinner, never chrome layered
        // on top of a blank/loading book.
        listenButton.isHidden = currentBook == nil || isReaderLoading
    }

    private func showEmptyState() {
        removeReaderControllerIfNeeded()
        emptyStateStack.isHidden = false
        listenButton.isHidden = true
        readerNavigationBar.isHidden = true
    }

    private func showBook(_ book: BookEntity) {
        emptyStateStack.isHidden = true
        readerNavigationBar.isHidden = false
        onReaderChromeVisibilityChanged?(false)
        readerNavigationItem.title = book.resolvedTitle
        if readerController != nil, readerBookID == book.id {
            // The existing reader already owns this book. Re-loading it on
            // every library notification causes `loadBook()` to publish a
            // loading-state change, which re-enters `render()` indefinitely.
            return
        }

        removeReaderControllerIfNeeded()

        let reader = BookOpenScreenController(
            book: book,
            library: library,
            settings: settings,
            bookmarkStore: bookmarkStore
        )
        isReaderLoading = true
        reader.onLoadStateChanged = { [weak self] isLoading in
            guard let self else { return }
            self.isReaderLoading = isLoading
            self.listenButton.isHidden = self.currentBook == nil || isLoading
        }
        reader.onChromeVisibilityChanged = { [weak self] isHidden in
            self?.readerNavigationBar.isHidden = isHidden
            self?.onReaderChromeVisibilityChanged?(isHidden)
        }
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reader.view)
        NSLayoutConstraint.activate([
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.topAnchor.constraint(equalTo: readerNavigationBar.bottomAnchor),
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reader.didMove(toParent: self)
        view.bringSubviewToFront(readerNavigationBar)
        readerController = reader
        readerBookID = book.id
        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: book.id,
            chapterIndex: ReaderProgressStore.read(bookId: book.id)?.chapterIndex ?? 0
        )

        // Do not mutate the library while rendering. `library.update` emits
        // `objectWillChange`, which calls `render()` again; updating
        // `lastOpenedAt` here creates an unbounded render/persist loop and
        // leaves the app at 100% CPU when a book is opened from the grid.
    }

    private func removeReaderControllerIfNeeded() {
        guard let readerController else { return }
        readerController.willMove(toParent: nil)
        readerController.view.removeFromSuperview()
        readerController.removeFromParent()
        self.readerController = nil
        self.readerBookID = nil
    }

    private func autoClearMissingBookIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              !library.books.contains(where: { $0.id == id }) else { return }
        ReaderSessionState.setCurrentlyReading(bookID: nil)
    }

    @objc
    private func closeReaderTapped() {
        ReaderSessionState.setCurrentlyReading(bookID: nil)
        onBrowseLibrary?()
    }

    @objc
    private func repickBookTapped() {
        readerController?.presentDocumentPicker()
    }

    @objc
    private func browseLibraryTapped() {
        onBrowseLibrary?()
    }

    // Mirrors `BookDetailScreenController.tapListen()` — the reader is now
    // the only iOS entry point for starting/resuming playback (Book Detail
    // no longer sits between the library grid and the reader).
    @objc
    private func listenTapped() {
        guard let book = currentBook else { return }
        if settings.useEmbeddedRuntime && !book.fileType.requiresServerConversion {
            guard let url = try? library.openBookFile(id: book.id) else { return }
            Task { [weak self] in
                guard let self else { return }
                do {
                    let snapshot = try await EmbeddedConversionCoordinator.stream(
                        bookURL: url,
                        bookID: book.id,
                        player: self.player
                    )
                    self.library.recordConversion(jobId: snapshot.jobId, for: book.id)
                    self.playerPresentation.showFullPlayer()
                } catch {
                    let alert = UIAlertController(
                        title: L10n.string("bookDetail.listenStart"),
                        message: error.localizedDescription,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                    self.present(alert, animated: true)
                }
            }
            return
        }
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
                playbackClock: player.playbackClock,
                preselectedFileURL: url,
                preselectedBookID: book.id
            ),
            animated: true
        )
    }
}
#endif
