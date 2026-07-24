#if os(iOS)
import Combine
import SwiftUI
import UIKit

struct IOSRootContainer: UIViewControllerRepresentable {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sidecar: SidecarManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var audioWarmup: AudioEngineWarmup
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var readerCoordinator: ReaderCoordinator

    func makeUIViewController(context: Context) -> IOSRootContainerController {
        IOSRootContainerController(
            settings: settings,
            sidecar: sidecar,
            library: library,
            player: player,
            audioWarmup: audioWarmup,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore,
            readerCoordinator: readerCoordinator
        )
    }

    func updateUIViewController(_ controller: IOSRootContainerController, context: Context) {
        controller.updateTheme(settings.readerTheme)
        controller.refreshOverlayState()
    }
}

@MainActor
final class IOSRootContainerController: UIViewController {
    private let settings: AppSettings
    private let sidecar: SidecarManager
    private let library: LibraryStore
    private let player: AudioPlayer
    private let audioWarmup: AudioEngineWarmup
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore
    private let readerCoordinator: ReaderCoordinator

    private let shellController: IOSAppShellController
    private let readerController: MainReaderScreenController
    private let miniPlayerController: MiniPlayerContainerController
    private let fullPlayerController: FullPlayerScreenController

    private var cancellables: Set<AnyCancellable> = []
    private var presentedErrorMessage: String?

    init(
        settings: AppSettings,
        sidecar: SidecarManager,
        library: LibraryStore,
        player: AudioPlayer,
        audioWarmup: AudioEngineWarmup,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore,
        readerCoordinator: ReaderCoordinator
    ) {
        self.settings = settings
        self.sidecar = sidecar
        self.library = library
        self.player = player
        self.audioWarmup = audioWarmup
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        self.readerCoordinator = readerCoordinator
        self.shellController = IOSAppShellController(
            settings: settings,
            library: library,
            player: player,
            playerPresentation: playerPresentation,
            bookmarkStore: bookmarkStore,
            readerCoordinator: readerCoordinator,
            audioWarmup: audioWarmup
        )
        self.readerController = MainReaderScreenController(
            library: library,
            settings: settings,
            player: player,
            audioWarmup: audioWarmup,
            playerPresentation: playerPresentation,
            onBrowseLibrary: {
                MainReaderView.setCurrentlyReading(bookID: nil)
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
            miniPlayerController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

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
                MainReaderView.setCurrentlyReading(bookID: nil)
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
        let currentlyReadingBookID = UserDefaults.standard.string(forKey: MainReaderView.currentlyReadingBookIDKey)
        let availableBookIDs = Set(library.books.map(\.id))
        let readerActive = currentlyReadingBookID.flatMap { id in availableBookIDs.contains(id) ? id : nil } != nil
        let showMini = RootView.shouldShowMiniPlayer(
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
