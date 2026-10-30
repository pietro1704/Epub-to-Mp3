#if os(iOS)
import AVFoundation
import AVKit
import Combine
import MediaPlayer
import UIKit

@MainActor
final class FullPlayerScreenController: UIViewController {
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock
    private var library: LibraryStore
    private let playerPresentation: PlayerPresentation
    private let settings: AppSettings
    private let onStartListening: () -> Void
    private let content = FullPlayerContent()
    private lazy var overlayTransition = PlayerOverlayTransition(view: view, style: .sheet)
    private lazy var dismissInteraction = FullPlayerDismissInteraction(
        view: view,
        controls: { [weak self] in self?.nonDraggableViews ?? [] },
        onBegin: { [weak self] in self?.overlayTransition.beginInteraction() ?? false },
        onCancel: { [weak self] in self?.overlayTransition.restoreAfterInteraction() },
        onDismiss: { [weak self] in self?.playerPresentation.dismissFullPlayer() }
    )
    private var renderedRate: PlaybackRate?

    private var cancellables: Set<AnyCancellable> = []
    private var isScrubbing = false
    private var currentBookID: String? {
        UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
    }

    init(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        playerPresentation: PlayerPresentation,
        settings: AppSettings,
        onStartListening: @escaping () -> Void
    ) {
        self.player = player
        self.playbackClock = playbackClock
        self.library = library
        self.playerPresentation = playerPresentation
        self.settings = settings
        self.onStartListening = onStartListening
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { false }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        content.install(in: view, actionTarget: self, actions: FullPlayerControlActions(
            closeTapped: #selector(closeTapped),
            scrubBegan: #selector(scrubBegan),
            scrubChanged: #selector(scrubChanged),
            scrubEnded: #selector(scrubEnded),
            previousChapterTapped: #selector(previousChapterTapped),
            skipBackTapped: #selector(skipBackTapped),
            playPauseTapped: #selector(playPauseTapped),
            skipForwardTapped: #selector(skipForwardTapped),
            nextChapterTapped: #selector(nextChapterTapped),
            tocTapped: #selector(tocTapped)
        ), traits: traitCollection)
        bind()
        render()

        // Attached to the whole view (rather than only the drag-handle strip)
        // so the drag also works when starting on the blurred background or
        // the title/author/chapter labels, matching Apple Music/Podcasts.
        // `gestureRecognizer(_:shouldReceive:)` below excludes every
        // interactive control's frame so the scrubber, transport buttons,
        // volume slider, and AirPlay button keep receiving their own touches
        // untouched.
        dismissInteraction.install()
    }

    func refresh(library: LibraryStore) {
        self.library = library
        render()
    }

    func setPresented(_ visible: Bool, animated: Bool) {
        overlayTransition.setVisible(visible, animated: animated)
    }

    private func bind() {
        [player.objectWillChange, library.objectWillChange, playerPresentation.objectWillChange]
            .forEach { publisher in
                publisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.render() }
                    .store(in: &cancellables)
            }

        playbackClock.$snapshot
            .sink { [weak self] snapshot in self?.renderPlaybackPosition(snapshot) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

    }

    private func render() {
        let currentBook = currentBookID.flatMap { id in
            library.books.first(where: { $0.id == id })
        }

        content.titleLabel.text = currentBook?.resolvedTitle ?? (player.snapshot?.bookTitle ?? L10n.string("player.audiobookFallback"))
        content.authorLabel.text = currentBook?.author
        content.authorLabel.isHidden = (content.authorLabel.text?.isEmpty ?? true)
        content.chapterLabel.text = player.snapshot == nil
            ? L10n.string("player.chapter", UserDefaults.standard.integer(forKey: AudioPlayer.currentChapterIndexDefaultsKey) + 1)
            : player.effectiveChapterTitle
        if let voice = player.snapshot?.activeVoiceDisplayName {
            content.chapterLabel.text = (content.chapterLabel.text ?? "") + "\n" + voice
        }

        if let data = currentBook?.coverPNG, let image = UIImage(data: data) {
            content.coverImageView.image = image
            content.coverImageView.contentMode = .scaleAspectFit
        } else {
            content.coverImageView.image = UIImage(systemName: "headphones")
            content.coverImageView.contentMode = .scaleAspectFit
        }

        content.layoutView.setNeedsLayout()
        renderPlaybackPosition()
        renderSkipButtons()
        renderPlayPauseButton()
        renderRateMenu()
        renderSleepMenu()
    }

    private func renderSkipButtons() {
        let backward = PlayerTransportPresentation.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey)
        let forward = PlayerTransportPresentation.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey)
        content.skipBackButton.setImage(UIImage(systemName: "gobackward.\(backward)"), for: .normal)
        content.skipForwardButton.setImage(UIImage(systemName: "goforward.\(forward)"), for: .normal)
        content.skipBackButton.accessibilityLabel = L10n.string("player.skipBack.seconds", backward)
        content.skipForwardButton.accessibilityLabel = L10n.string("player.skipForward.seconds", forward)
    }

    private func renderPlaybackPosition(_ clockSnapshot: PlaybackClock.Snapshot? = nil) {
        let snapshot = clockSnapshot ?? playbackClock.snapshot
        content.slider.maximumValue = Float(max(snapshot.durationSeconds, 1))
        content.slider.isEnabled = snapshot.durationSeconds > 0
        let position = player.isSeeking ? player.positionSeconds : snapshot.positionSeconds
        if !isScrubbing && !player.isSeeking {
            content.slider.value = Float(position)
        }
        content.elapsedLabel.text = (player.isPositionApproximate ? "≈ " : "")
            + PlayerTransportPresentation.formatTime(position)
        let timeline = ChapterPlaybackTimeline(
            estimate: player.isChapterDurationEstimated ? snapshot.durationSeconds : nil,
            confirmed: player.isChapterDurationEstimated ? nil : snapshot.durationSeconds)
        let rateAdjusted = timeline.remaining(position: position, rate: Double(player.rate.rawValue))
        let prefix = player.isChapterDurationEstimated ? "≈ -" : "-"
        content.remainingLabel.text = snapshot.durationSeconds > 0
            ? prefix + PlayerTransportPresentation.formatTime(rateAdjusted) : "—"
        content.remainingLabel.accessibilityLabel = player.isChapterDurationEstimated
            ? L10n.string("player.estimatedRemaining", PlayerTransportPresentation.formatTime(rateAdjusted))
            : nil
    }

    private func renderPlayPauseButton() {
        if player.isLoading {
            content.playPauseButton.setImage(nil, for: .normal)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            content.playPauseButton.configuration = nil
            content.playPauseButton.subviews.forEach { subview in
                if subview is UIActivityIndicatorView { subview.removeFromSuperview() }
            }
            spinner.translatesAutoresizingMaskIntoConstraints = false
            content.playPauseButton.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: content.playPauseButton.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: content.playPauseButton.centerYAnchor),
            ])
        } else {
            content.playPauseButton.subviews.forEach {
                if $0 is UIActivityIndicatorView { $0.removeFromSuperview() }
            }
            content.playPauseButton.setImage(
                UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill"),
                for: .normal
            )
            content.playPauseButton.imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        }
        content.playPauseButton.accessibilityLabel = player.isPlaying
            ? L10n.string("player.pause")
            : L10n.string("player.play")
    }

    private func renderRateMenu() {
        guard renderedRate != player.rate || content.rateButton.menu == nil else { return }
        renderedRate = player.rate
        var config = content.rateButton.configuration ?? UIButton.Configuration.plain()
        config.title = player.rate.shortLabel
        content.rateButton.configuration = config
        content.rateButton.menu = UIMenu(children: PlaybackRate.primaryRates.map { rate in
            UIAction(title: rate.shortLabel, state: rate == player.rate ? .on : .off) { [weak self] _ in
                self?.player.setRate(rate)
                self?.render()
            }
        })
    }

    private func renderSleepMenu() {
        let minutes = [0, 5, 15, 30, 45, 60]
        content.sleepButton.menu = UIMenu(children: minutes.map { minute in
            if minute == 0 {
                return UIAction(title: L10n.string("player.sleepTimerOption.off")) { [weak self] _ in
                    self?.player.setSleepTimer(seconds: 0)
                    self?.render()
                }
            }
            return UIAction(title: L10n.string("player.sleepTimerOption.\(minute)")) { [weak self] _ in
                self?.player.startSleepTimer(minutes: minute)
                self?.render()
            }
        })
        content.sleepButton.accessibilityLabel = L10n.string("player.sleepTimer")
    }

    @objc
    private func closeTapped() {
        playerPresentation.dismissFullPlayer()
    }

    /// Interactive controls whose own gesture/touch handling must never be
    /// stolen by `dismissPanGesture` (see `gestureRecognizer(_:shouldReceive:)`
    /// below). Computed rather than cached so it always reflects current
    /// frames/visibility without needing invalidation on layout changes.
    private var nonDraggableViews: [UIView] {
        [
            content.slider, content.volumeView, content.airPlayContainer,
            content.previousChapterButton, content.skipBackButton, content.playPauseButton, content.skipForwardButton, content.nextChapterButton,
            content.rateButton, content.tocButton, content.sleepButton,
        ]
    }

    @objc
    private func previousChapterTapped() {
        player.previousChapter()
        render()
    }

    @objc
    private func skipBackTapped() {
        player.skipBackward()
        render()
    }

    @objc
    private func playPauseTapped() {
        InAppPlaybackRequest.perform(
            state: player.inAppPlaybackRequestState,
            controlPlayback: { ReaderPlaybackTapHandler.handle(player: player, presenting: self) },
            startListening: onStartListening
        )
        render()
    }

    @objc
    private func skipForwardTapped() {
        player.skipForward()
        render()
    }

    @objc
    private func nextChapterTapped() {
        player.nextChapter()
        render()
    }

    @objc
    private func scrubBegan() {
        isScrubbing = true
    }

    @objc
    private func scrubChanged() {
        content.elapsedLabel.text = PlayerTransportPresentation.formatTime(TimeInterval(content.slider.value))
    }

    @objc
    private func scrubEnded() {
        isScrubbing = false
        player.seek(to: TimeInterval(content.slider.value))
        render()
    }

    @objc
    private func tocTapped() {
        guard let snapshot = player.snapshot else { return }
        let fulltext = currentBookID.flatMap { LocalFulltextCache.read(bookId: $0) }
        let playableChapters = snapshot.playableChapters
        let playingEpubIndex = playableChapters.indices.contains(player.currentChapterIndex)
            ? playableChapters[player.currentChapterIndex].index
            : -1
        let controller = UINavigationController(
            rootViewController: TocScreenController(
                fulltext: fulltext,
                snapshot: snapshot,
                currentChapterIndex: playingEpubIndex,
                readingChapterIndex: nil,
                onJump: { [weak self] epubIndex in
                    guard let self,
                          let playable = playableChapters.firstIndex(where: { $0.index == epubIndex }) else { return }
                    self.player.play(snapshot: snapshot, startingAt: playable)
                },
                onDownload: { [weak self] chapterIndex in
                    guard let self else { return }
                    self.requestAudioDownload(snapshot: snapshot, chapterIndex: chapterIndex)
                },
                onRemoveDownload: { chapterIndex in
                    AudiobookDownloadStorage.deleteChapter(jobId: snapshot.jobId, chapterIndex: chapterIndex)
                },
                onDownloadAll: { [weak self] in
                    guard let self else { return }
                    self.requestAudioDownload(snapshot: snapshot, chapterIndex: nil)
                },
                onCancelDownloads: { Task { await AudiobookDownloads.shared.cancel(jobId: snapshot.jobId) } },
                onClearDownloads: { Task { await AudiobookDownloads.shared.clearDownloadedBook(jobId: snapshot.jobId) } },
                onRetryFailed: nil,
                onExport: nil
            )
        )
        if let sheet = controller.sheetPresentationController {
            if #available(iOS 16.0, *) {
                sheet.detents = [
                    UISheetPresentationController.Detent.medium(),
                    UISheetPresentationController.Detent.large()
                ]
            }
        }
        present(controller, animated: true)
    }

    private func requestAudioDownload(snapshot: JobSnapshot, chapterIndex: Int?) {
        Task {
            if let chapterIndex {
                await AudiobookDownloads.shared.enqueueSelected(snapshot: snapshot, epubZeroBasedIndices: [chapterIndex], baseURL: settings.resolvedBaseURL)
            } else {
                await AudiobookDownloads.shared.enqueueAll(snapshot: snapshot, baseURL: settings.resolvedBaseURL)
            }
        }
    }


}

#endif
