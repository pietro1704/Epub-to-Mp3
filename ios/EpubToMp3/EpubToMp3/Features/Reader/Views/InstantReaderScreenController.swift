#if os(iOS)
import SwiftUI
import UIKit

struct InstantReaderScreenHost: UIViewControllerRepresentable {
    let fulltext: EbookFulltext
    @Binding var snapshot: JobSnapshot?
    let statusBanner: String?
    let hasAudio: Bool
    let backendBaseURL: URL?
    let coverPNG: Data?
    let onRequestAudioRetry: () -> Void
    var onRequestPlay: ((Int, String?) -> Void)?
    var onClose: (() -> Void)?
    @ObservedObject var cacheManager: ChapterCacheManager

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var playerPresentation: PlayerPresentation
    @EnvironmentObject private var readerCoordinator: ReaderCoordinator

    func makeUIViewController(context: Context) -> InstantReaderScreenController {
        InstantReaderScreenController(
            fulltext: fulltext,
            snapshot: $snapshot,
            statusBanner: statusBanner,
            hasAudio: hasAudio,
            backendBaseURL: backendBaseURL,
            coverPNG: coverPNG,
            onRequestAudioRetry: onRequestAudioRetry,
            onRequestPlay: onRequestPlay,
            onClose: onClose,
            cacheManager: cacheManager,
            settings: settings,
            player: player,
            playerPresentation: playerPresentation,
            readerCoordinator: readerCoordinator
        )
    }

    func updateUIViewController(_ uiViewController: InstantReaderScreenController, context: Context) {
        uiViewController.update(
            fulltext: fulltext,
            snapshot: $snapshot,
            statusBanner: statusBanner,
            hasAudio: hasAudio,
            backendBaseURL: backendBaseURL,
            coverPNG: coverPNG,
            onRequestAudioRetry: onRequestAudioRetry,
            onRequestPlay: onRequestPlay,
            onClose: onClose,
            cacheManager: cacheManager,
            settings: settings,
            player: player,
            playerPresentation: playerPresentation,
            readerCoordinator: readerCoordinator
        )
    }
}

@MainActor
final class InstantReaderScreenController: UIViewController {
    private var fulltext: EbookFulltext
    private var snapshot: Binding<JobSnapshot?>
    private var statusBanner: String?
    private var hasAudio: Bool
    private var backendBaseURL: URL?
    private var coverPNG: Data?
    private var onRequestAudioRetry: () -> Void
    private var onRequestPlay: ((Int, String?) -> Void)?
    private var onClose: (() -> Void)?
    private var cacheManager: ChapterCacheManager
    private var settings: AppSettings
    private var player: AudioPlayer
    private var playerPresentation: PlayerPresentation
    private var readerCoordinator: ReaderCoordinator
    private let readingState = InstantReaderReadingState()
    private let presentationState = InstantReaderPresentationState()
    private var preparedStateJobID: String?

    private var hostedController: UIHostingController<AnyView>?

    init(
        fulltext: EbookFulltext,
        snapshot: Binding<JobSnapshot?>,
        statusBanner: String?,
        hasAudio: Bool,
        backendBaseURL: URL?,
        coverPNG: Data?,
        onRequestAudioRetry: @escaping () -> Void,
        onRequestPlay: ((Int, String?) -> Void)?,
        onClose: (() -> Void)?,
        cacheManager: ChapterCacheManager,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        readerCoordinator: ReaderCoordinator
    ) {
        self.fulltext = fulltext
        self.snapshot = snapshot
        self.statusBanner = statusBanner
        self.hasAudio = hasAudio
        self.backendBaseURL = backendBaseURL
        self.coverPNG = coverPNG
        self.onRequestAudioRetry = onRequestAudioRetry
        self.onRequestPlay = onRequestPlay
        self.onClose = onClose
        self.cacheManager = cacheManager
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.readerCoordinator = readerCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        mountContentIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persistLifecycleState()
    }

    func update(
        fulltext: EbookFulltext,
        snapshot: Binding<JobSnapshot?>,
        statusBanner: String?,
        hasAudio: Bool,
        backendBaseURL: URL?,
        coverPNG: Data?,
        onRequestAudioRetry: @escaping () -> Void,
        onRequestPlay: ((Int, String?) -> Void)?,
        onClose: (() -> Void)?,
        cacheManager: ChapterCacheManager,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        readerCoordinator: ReaderCoordinator
    ) {
        self.fulltext = fulltext
        self.snapshot = snapshot
        self.statusBanner = statusBanner
        self.hasAudio = hasAudio
        self.backendBaseURL = backendBaseURL
        self.coverPNG = coverPNG
        self.onRequestAudioRetry = onRequestAudioRetry
        self.onRequestPlay = onRequestPlay
        self.onClose = onClose
        self.cacheManager = cacheManager
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.readerCoordinator = readerCoordinator
        mountContentIfNeeded()
    }

    private func mountContentIfNeeded() {
        prepareInitialReadingStateIfNeeded()

        let rootView = AnyView(
            InstantReaderContentView(
                fulltext: fulltext,
                snapshot: snapshot,
                statusBanner: statusBanner,
                hasAudio: hasAudio,
                backendBaseURL: backendBaseURL,
                coverPNG: coverPNG,
                onRequestAudioRetry: onRequestAudioRetry,
                onRequestPlay: onRequestPlay,
                onClose: onClose,
                cacheManager: cacheManager,
                readingState: readingState,
                presentationState: presentationState,
                onShowToc: { [weak self] audioChapterIndex, readingChapterIndex, playerMounted, snapshot in
                    self?.presentToc(
                        audioChapterIndex: audioChapterIndex,
                        readingChapterIndex: readingChapterIndex,
                        playerMounted: playerMounted,
                        snapshot: snapshot
                    )
                },
                onShowSearch: { [weak self] in
                    self?.presentSearch()
                },
                onShowReaderSettings: { [weak self] in
                    self?.presentReaderSettings()
                },
                onShowConversionStatus: { [weak self] in
                    self?.presentConversionStatus()
                },
                onChapterIndexChanged: { [weak self] newIndex in
                    self?.handleCurrentChapterChanged(newIndex)
                },
                onCloseAudioPlayer: { [weak self] in
                    self?.handleCloseAudioPlayer()
                },
                onReopenAudioPlayer: { [weak self] currentChapterIndex in
                    self?.handleReopenAudioPlayer(currentChapterIndex: currentChapterIndex)
                },
                onAutoHideChrome: { [weak self] in
                    self?.handleAutoHideChrome()
                },
                onRestoreChrome: { [weak self] in
                    self?.handleRestoreChrome()
                }
            )
            .environmentObject(settings)
            .environmentObject(player)
            .environmentObject(playerPresentation)
            .environmentObject(readerCoordinator)
        )

        if let hostedController {
            hostedController.rootView = rootView
            return
        }

        let host = UIHostingController(rootView: rootView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostedController = host
    }

    private func prepareInitialReadingStateIfNeeded() {
        guard preparedStateJobID != fulltext.jobId else { return }
        preparedStateJobID = fulltext.jobId

        presentationState.restore(for: fulltext.jobId)
        let forceReset = ProcessInfo.processInfo.arguments.contains("-uiTestResetReaderPosition")
        let shouldAutoResume = readingState.restoreInitialPosition(
            fulltext: fulltext,
            settings: settings,
            readerCoordinator: readerCoordinator,
            player: player,
            forceReset: forceReset
        )
        readerCoordinator.setChapter(readingState.currentChapterIndex)

        if shouldAutoResume {
            player.armPersistedResume()
            onRequestPlay?(readingState.currentChapterIndex, nil)
        }
    }

    private func presentReaderSettings() {
        let controller = UINavigationController(
            rootViewController: ReaderSettingsScreenController(settings: settings)
        )
        present(controller, animated: true)
    }

    private func presentSearch() {
        let controller = ReaderSearchScreenController(
            chapters: fulltext.chapters,
            onJumpToChapter: { [weak self] idx in
                self?.readingState.currentChapterIndex = max(0, idx - 1)
            },
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func presentToc(
        audioChapterIndex: Int,
        readingChapterIndex: Int,
        playerMounted: Bool,
        snapshot: JobSnapshot
    ) {
        let controller = TocScreenController(
            fulltext: fulltext,
            snapshot: snapshot,
            currentChapterIndex: audioChapterIndex,
            readingChapterIndex: readingChapterIndex,
            onJump: { [weak self] target in
                self?.handleTocJump(target, playerMounted: playerMounted, snapshot: snapshot)
            },
            onDownload: { [weak self] in self?.cacheManager.downloadChapter($0) },
            onDownloadAll: { [weak self] in self?.cacheManager.downloadAll() },
            onCancelDownloads: { [weak self] in self?.cacheManager.cancelAll() },
            onClearDownloads: { [weak self] in self?.cacheManager.clearAll() }
        )
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func handleTocJump(_ target: Int, playerMounted: Bool, snapshot: JobSnapshot) {
        readingState.pinnedReaderChapterIndex = target
        readingState.currentChapterIndex = target
        if playerMounted {
            let playableTarget = InstantReaderIndexMapper
                .playableIndex(forEpubIndex: target, in: snapshot) ?? 0
            player.play(snapshot: snapshot, startingAt: playableTarget)
        }
        presentationState.restoreChromeIfNeeded()
    }

    private func handleCurrentChapterChanged(_ newIndex: Int) {
        settings.saveChapterIndex(newIndex, for: fulltext.jobId)
        // ReaderCoordinator remains the source of truth for cross-surface
        // reader position and clears stale sentence/page anchors on chapter jumps.
        readerCoordinator.setChapter(newIndex)
        WidgetDataSync.updateLastRead(
            bookId: fulltext.jobId,
            chapterIndex: newIndex,
            totalChapters: fulltext.chapters.count
        )
        cacheManager.refreshCachedIndices()
    }

    private func handleCloseAudioPlayer() {
        player.stop()
        playerPresentation.dismissFullPlayer()
        presentationState.hideAudioPlayer()
    }

    private func handleReopenAudioPlayer(currentChapterIndex: Int) {
        presentationState.showAudioPlayer()
        onRequestPlay?(currentChapterIndex, nil)
    }

    private func handleAutoHideChrome() {
        presentationState.autoHideChromeIfNeeded()
    }

    private func handleRestoreChrome() {
        presentationState.restoreChromeIfNeeded()
    }

    private func presentConversionStatus() {
        let controller = UINavigationController(
            rootViewController: ConversionStatusScreenController(
                status: player.conversionStatus,
                bookTitle: fulltext.bookTitle ?? "Book",
                onCancel: { [weak self] in
                    self?.onRequestAudioRetry()
                },
                onRetry: { [weak self] in
                    self?.onRequestAudioRetry()
                }
            )
        )
        present(controller, animated: true)
    }

    private func persistLifecycleState() {
        settings.saveChapterIndex(readingState.currentChapterIndex, for: fulltext.jobId)
        WidgetDataSync.updateLastRead(
            bookId: fulltext.jobId,
            chapterIndex: readingState.currentChapterIndex,
            totalChapters: fulltext.chapters.count
        )
        WidgetDataSync.flushLastRead()
        readerCoordinator.flush()
        presentationState.persist(
            for: fulltext.jobId,
            fullPlayerVisible: playerPresentation.showingFullPlayer
        )
    }
}
#endif
