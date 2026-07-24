#if os(iOS)
import Combine
import UIKit

@MainActor
final class MainReaderScreenController: UIViewController {
    private var library: LibraryStore
    private var settings: AppSettings
    private let player: AudioPlayer
    private let audioWarmup: AudioEngineWarmup
    private let playerPresentation: PlayerPresentation
    private var onBrowseLibrary: (() -> Void)?

    private var cancellables: Set<AnyCancellable> = []
    private var hostedController: BookOpenScreenController?
    private var hostedBookID: String?

    private let emptyStateStack = UIStackView()
    private let emptyTitleLabel = UILabel()
    private let emptyDescriptionLabel = UILabel()
    private let browseButton = UIButton(type: .system)
    private let listenButton = UIButton(type: .system)

    private var currentBook: BookEntity? {
        guard let id = UserDefaults.standard.string(forKey: MainReaderView.currentlyReadingBookIDKey),
              !id.isEmpty else { return nil }
        return library.books.first(where: { $0.id == id })
    }

    init(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        audioWarmup: AudioEngineWarmup,
        playerPresentation: PlayerPresentation,
        onBrowseLibrary: (() -> Void)?
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.audioWarmup = audioWarmup
        self.playerPresentation = playerPresentation
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
            listenButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            listenButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            listenButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
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
        removeHostedControllerIfNeeded()
        emptyStateStack.isHidden = false
        listenButton.isHidden = true
    }

    private func showBook(_ book: BookEntity) {
        emptyStateStack.isHidden = true
        if let hostedController, hostedBookID == book.id {
            hostedController.update(
                book: book,
                onClose: { [weak self] in
                    MainReaderView.setCurrentlyReading(bookID: nil)
                    self?.onBrowseLibrary?()
                },
                library: library,
                settings: settings,
                player: player,
                audioWarmup: audioWarmup
            )
            return
        }

        removeHostedControllerIfNeeded()

        let host = BookOpenScreenController(
            book: book,
            onClose: { [weak self] in
                MainReaderView.setCurrentlyReading(bookID: nil)
                self?.onBrowseLibrary?()
            },
            library: library,
            settings: settings,
            player: player,
            audioWarmup: audioWarmup
        )
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(host.view, belowSubview: listenButton)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostedController = host
        hostedBookID = book.id

        var updated = book
        updated.lastOpenedAt = Date()
        library.update(updated)
    }

    private func removeHostedControllerIfNeeded() {
        guard let hostedController else { return }
        hostedController.willMove(toParent: nil)
        hostedController.view.removeFromSuperview()
        hostedController.removeFromParent()
        self.hostedController = nil
        self.hostedBookID = nil
    }

    private func autoClearMissingBookIfNeeded() {
        guard let id = UserDefaults.standard.string(forKey: MainReaderView.currentlyReadingBookIDKey),
              !library.books.contains(where: { $0.id == id }) else { return }
        MainReaderView.setCurrentlyReading(bookID: nil)
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
