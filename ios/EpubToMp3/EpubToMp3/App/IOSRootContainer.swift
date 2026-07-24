#if os(iOS)
import Combine
import UIKit

@MainActor
final class IOSRootContainerController: UIViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore

    private let shellController: IOSAppShellController
    private let readerController: MainReaderScreenController
    private let miniPlayerController: MiniPlayerContainerController
    private let fullPlayerController: FullPlayerScreenController

    private var cancellables: Set<AnyCancellable> = []
    private var presentedErrorMessage: String?

    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore
    ) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        self.shellController = IOSAppShellController(
            settings: settings,
            library: library,
            player: player,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore
        )
        self.readerController = MainReaderScreenController(
            library: library,
            settings: settings,
            player: player,
            playerPresentation: playerPresentation,
            onBrowseLibrary: {
                ReaderSessionState.setCurrentlyReading(bookID: nil)
            }
        )
        self.miniPlayerController = MiniPlayerContainerController(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: {
                playerPresentation.showFullPlayer()
            }
        )
        self.fullPlayerController = FullPlayerScreenController(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            playerPresentation: playerPresentation
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        embed(shellController)
        embed(readerController)
        embed(miniPlayerController)
        embed(fullPlayerController)

        shellController.view.translatesAutoresizingMaskIntoConstraints = false
        readerController.view.translatesAutoresizingMaskIntoConstraints = false
        miniPlayerController.view.translatesAutoresizingMaskIntoConstraints = false
        fullPlayerController.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            shellController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shellController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shellController.view.topAnchor.constraint(equalTo: view.topAnchor),
            shellController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            readerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            readerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            miniPlayerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            miniPlayerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Keep the mini-player above the tab bar instead of covering it.
            miniPlayerController.view.bottomAnchor.constraint(equalTo: shellController.tabBar.topAnchor),

            fullPlayerController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fullPlayerController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fullPlayerController.view.topAnchor.constraint(equalTo: view.topAnchor),
            fullPlayerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        readerController.view.backgroundColor = .clear
        miniPlayerController.view.backgroundColor = .clear
        fullPlayerController.view.backgroundColor = .clear

        bindState()
        updateTheme(settings.readerTheme)
        refreshOverlayState()
    }

    func updateTheme(_ theme: ReaderTheme) {
        shellController.applyTheme(theme)
        readerController.update(
            library: library,
            settings: settings,
            onBrowseLibrary: {
                ReaderSessionState.setCurrentlyReading(bookID: nil)
            }
        )
        miniPlayerController.update(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: {
                self.playerPresentation.showFullPlayer()
            }
        )
        fullPlayerController.refresh(library: library)
        switch theme.preferredColorScheme {
        case .dark:
            overrideUserInterfaceStyle = .dark
        case .light:
            overrideUserInterfaceStyle = .light
        case nil:
            overrideUserInterfaceStyle = .unspecified
        @unknown default:
            overrideUserInterfaceStyle = .unspecified
        }
    }

    func refreshOverlayState() {
        let currentBookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let currentlyReadingBookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let availableBookIDs = Set(library.books.map(\.id))
        let readerActive = currentlyReadingBookID.flatMap { id in availableBookIDs.contains(id) ? id : nil } != nil
        let showMini = IOSMiniPlayerPolicy.shouldShow(
            currentBookID: currentBookID,
            currentlyReadingBookID: currentlyReadingBookID,
            availableBookIDs: availableBookIDs
        )

        readerController.view.isHidden = !readerActive
        miniPlayerController.view.isHidden = !showMini
        fullPlayerController.view.isHidden = !playerPresentation.showingFullPlayer
        fullPlayerController.view.alpha = playerPresentation.showingFullPlayer ? 1 : 0
        presentPlayerErrorIfNeeded()
    }

    private func bindState() {
        playerPresentation.objectWillChange
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
        library.objectWillChange
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
        player.objectWillChange
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in self?.refreshOverlayState() }
            .store(in: &cancellables)
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    private func presentPlayerErrorIfNeeded() {
        guard let error = player.lastError?.errorDescription, error != presentedErrorMessage else { return }
        presentedErrorMessage = error
        let alert = UIAlertController(
            title: L10n.string("player.error.title"),
            message: error,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default) { [weak self] _ in
            self?.player.lastError = nil
            self?.presentedErrorMessage = nil
        })
        if presentedViewController == nil {
            present(alert, animated: true)
        }
    }
}

@MainActor
private final class MiniPlayerContainerController: UIViewController {
    private let miniPlayerView = MiniPlayerBarUIKitView()

    init(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void
    ) {
        super.init(nibName: nil, bundle: nil)
        miniPlayerView.configure(
            player: player,
            playbackClock: playbackClock,
            library: library,
            onTap: onTap
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = miniPlayerView
        view.accessibilityIdentifier = "miniPlayer.container"
    }

    func update(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void
    ) {
        miniPlayerView.configure(
            player: player,
            playbackClock: playbackClock,
            library: library,
            onTap: onTap
        )
    }
}
#endif
