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

    private var cancellables: Set<AnyCancellable> = []
    private var readerController: BookOpenScreenController?
    private var readerBookID: String?

    private let emptyStateStack = UIStackView()
    private let emptyTitleLabel = UILabel()
    private let emptyDescriptionLabel = UILabel()
    private let browseButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)
    private let readerToolbar = UIStackView()
    private let readerTitleLabel = UILabel()
    private let closeReaderButton = UIButton(type: .system)
    private let repickBookButton = UIButton(type: .system)

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
        configureReaderToolbar()
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
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "headphones")
        config.title = L10n.string("mainReader.listen")
        config.imagePadding = 6
        listenButton.configuration = config
        listenButton.translatesAutoresizingMaskIntoConstraints = false
        listenButton.accessibilityIdentifier = "mainReader.listen"
        listenButton.addTarget(self, action: #selector(listenTapped), for: .touchUpInside)
        view.addSubview(listenButton)
        NSLayoutConstraint.activate([
            listenButton.topAnchor.constraint(equalTo: readerToolbar.bottomAnchor, constant: 8),
            listenButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            listenButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func configureReaderToolbar() {
        readerToolbar.axis = .horizontal
        readerToolbar.alignment = .center
        readerToolbar.spacing = 8
        readerToolbar.isLayoutMarginsRelativeArrangement = true
        readerToolbar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
        readerToolbar.translatesAutoresizingMaskIntoConstraints = false

        var closeConfiguration = UIButton.Configuration.plain()
        closeConfiguration.image = UIImage(systemName: "xmark")
        closeConfiguration.contentInsets = .zero
        closeReaderButton.configuration = closeConfiguration
        closeReaderButton.accessibilityLabel = L10n.string("player.close")
        closeReaderButton.accessibilityIdentifier = "reader.close"
        closeReaderButton.addTarget(self, action: #selector(closeReaderTapped), for: .touchUpInside)

        readerTitleLabel.font = .preferredFont(forTextStyle: .headline)
        readerTitleLabel.textAlignment = .center
        readerTitleLabel.lineBreakMode = .byTruncatingMiddle
        readerTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var repickConfiguration = UIButton.Configuration.plain()
        repickConfiguration.title = L10n.string("bookOpen.repick")
        repickConfiguration.contentInsets = .zero
        repickBookButton.configuration = repickConfiguration
        repickBookButton.accessibilityIdentifier = "reader.repick"
        repickBookButton.addTarget(self, action: #selector(repickBookTapped), for: .touchUpInside)

        readerToolbar.addArrangedSubview(closeReaderButton)
        readerToolbar.addArrangedSubview(readerTitleLabel)
        readerToolbar.addArrangedSubview(repickBookButton)
        view.addSubview(readerToolbar)
        NSLayoutConstraint.activate([
            readerToolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerToolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerToolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            readerToolbar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            closeReaderButton.widthAnchor.constraint(equalToConstant: 44),
            repickBookButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    private func render() {
        if let book = currentBook {
            showBook(book)
        } else {
            showEmptyState()
        }
        listenButton.isHidden = currentBook?.lastJobId == nil
    }

    private func showEmptyState() {
        removeReaderControllerIfNeeded()
        emptyStateStack.isHidden = false
        listenButton.isHidden = true
        readerToolbar.isHidden = true
    }

    private func showBook(_ book: BookEntity) {
        emptyStateStack.isHidden = true
        readerToolbar.isHidden = false
        readerTitleLabel.text = book.resolvedTitle
        if let readerController, readerBookID == book.id {
            readerController.update(
                book: book
            )
            return
        }

        removeReaderControllerIfNeeded()

        let reader = BookOpenScreenController(
            book: book,
            library: library,
            settings: settings,
            bookmarkStore: bookmarkStore
        )
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(reader.view, belowSubview: listenButton)
        NSLayoutConstraint.activate([
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.topAnchor.constraint(equalTo: readerToolbar.bottomAnchor),
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reader.didMove(toParent: self)
        readerController = reader
        readerBookID = book.id

        var updated = book
        updated.lastOpenedAt = Date()
        library.update(updated)
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

    @objc
    private func listenTapped() {
        guard let bookID = currentBook?.id else { return }
        UserDefaults.standard.set(bookID, forKey: AudioPlayer.currentBookIDDefaultsKey)
        playerPresentation.showFullPlayer()
    }
}
#endif
