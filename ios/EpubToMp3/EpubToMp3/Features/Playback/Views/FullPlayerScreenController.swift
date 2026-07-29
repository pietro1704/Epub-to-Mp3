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

    private var cancellables: Set<AnyCancellable> = []
    private var positionTask: Task<Void, Never>?
    private var isScrubbing = false
    private var currentBookID: String? {
        UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
    }

    private let closeButton = UIButton(type: .system)
    private let dragHandle = UIView()
    private lazy var dismissPanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleDismissPan(_:))
    )
    private let coverContainer = UIView()
    private let coverImageView = UIImageView()
    private let titleLabel = UILabel()
    private let authorLabel = UILabel()
    private let chapterLabel = UILabel()
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let previousChapterButton = UIButton(type: .system)
    private let skipBackButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let nextChapterButton = UIButton(type: .system)
    private let rateButton = UIButton(type: .system)
    private let tocButton = UIButton(type: .system)
    private let sleepButton = UIButton(type: .system)
    private let airPlayContainer = UIView()
    // The legacy route-button configuration is intentionally omitted.
    // since iOS 13 (this project builds with SWIFT_TREAT_WARNINGS_AS_ERRORS,
    // so the deprecation is a hard build failure, not just a warning).
    // `AVRoutePickerView` is Apple's replacement and is exactly an AirPlay
    // route button by design — no extra config needed to hide the volume
    // slider like MPVolumeView required.
    private let airPlayView = AVRoutePickerView(frame: .zero)
    private let volumeView = MPVolumeView(frame: .zero)
    private let stackView = UIStackView()

    init(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        playerPresentation: PlayerPresentation
    ) {
        self.player = player
        self.playbackClock = playbackClock
        self.library = library
        self.playerPresentation = playerPresentation
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
        buildUI()
        bind()
        render()

        // Attached to the whole view (rather than only the drag-handle strip)
        // so the drag also works when starting on the blurred background or
        // the title/author/chapter labels, matching Apple Music/Podcasts.
        // `gestureRecognizer(_:shouldReceive:)` below excludes every
        // interactive control's frame so the scrubber, transport buttons,
        // volume slider, and AirPlay button keep receiving their own touches
        // untouched.
        dismissPanGesture.delegate = self
        view.addGestureRecognizer(dismissPanGesture)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            positionTask?.cancel()
        }
    }

    func refresh(library: LibraryStore) {
        self.library = library
        render()
    }

    private func buildUI() {
        let background = AdaptiveMaterialView()
        view.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // HIG-standard grabber affordance signalling "this can be dragged" —
        // purely visual, the pan gesture is attached to `view` itself (see
        // viewDidLoad) so dragging also works from the background/labels.
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragHandle.backgroundColor = .tertiaryLabel
        dragHandle.layer.cornerRadius = 2.5
        dragHandle.isUserInteractionEnabled = false
        dragHandle.accessibilityIdentifier = "fullPlayer.dragHandle"
        view.addSubview(dragHandle)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .label
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.accessibilityIdentifier = "fullPlayer.close"
        closeButton.accessibilityLabel = L10n.string("player.close")
        view.addSubview(closeButton)

        coverContainer.translatesAutoresizingMaskIntoConstraints = false
        coverContainer.layer.cornerRadius = 16
        coverContainer.layer.masksToBounds = true
        coverContainer.backgroundColor = UIColor.tintColor.withAlphaComponent(0.15)

        coverImageView.translatesAutoresizingMaskIntoConstraints = false
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.image = UIImage(systemName: "headphones")
        coverImageView.tintColor = .tintColor
        coverContainer.addSubview(coverImageView)
        NSLayoutConstraint.activate([
            coverImageView.leadingAnchor.constraint(equalTo: coverContainer.leadingAnchor),
            coverImageView.trailingAnchor.constraint(equalTo: coverContainer.trailingAnchor),
            coverImageView.topAnchor.constraint(equalTo: coverContainer.topAnchor),
            coverImageView.bottomAnchor.constraint(equalTo: coverContainer.bottomAnchor),
        ])

        titleLabel.font = .preferredFont(forTextStyle: .title2).bold()
        titleLabel.numberOfLines = 2
        titleLabel.textAlignment = .center

        authorLabel.font = .preferredFont(forTextStyle: .subheadline)
        authorLabel.textColor = .secondaryLabel
        authorLabel.textAlignment = .center

        chapterLabel.font = .preferredFont(forTextStyle: .footnote)
        chapterLabel.textColor = .tertiaryLabel
        chapterLabel.numberOfLines = 2
        chapterLabel.textAlignment = .center

        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        [elapsedLabel, remainingLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            $0.textColor = .secondaryLabel
        }

        configureTransportButton(previousChapterButton, image: "backward.end.fill", action: #selector(previousChapterTapped))
        configureTransportButton(skipBackButton, image: "gobackward.15", action: #selector(skipBackTapped), pointSize: 28)
        configureTransportButton(playPauseButton, image: "play.circle.fill", action: #selector(playPauseTapped), pointSize: 64)
        configureTransportButton(skipForwardButton, image: "goforward.15", action: #selector(skipForwardTapped), pointSize: 28)
        configureTransportButton(nextChapterButton, image: "forward.end.fill", action: #selector(nextChapterTapped))

        let transport = UIStackView(arrangedSubviews: [
            previousChapterButton, skipBackButton, playPauseButton, skipForwardButton, nextChapterButton
        ])
        transport.axis = .horizontal
        transport.alignment = .center
        transport.distribution = .equalSpacing
        transport.spacing = 12

        var rateConfig = UIButton.Configuration.plain()
        rateConfig.contentInsets = .init(top: 8, leading: 12, bottom: 8, trailing: 12)
        rateConfig.background.backgroundColor = .secondarySystemFill
        rateConfig.background.cornerRadius = 10
        rateButton.configuration = rateConfig
        rateButton.translatesAutoresizingMaskIntoConstraints = false
        rateButton.accessibilityIdentifier = "fullPlayer.playbackRateButton"
        rateButton.accessibilityLabel = L10n.string("player.speed")
        rateButton.showsMenuAsPrimaryAction = true

        configureSecondaryButton(tocButton, image: "list.bullet", title: nil, action: #selector(tocTapped))
        configureSecondaryButton(sleepButton, image: "moon.zzz", title: nil, action: nil)
        tocButton.accessibilityLabel = L10n.string("reader.toc")
        sleepButton.showsMenuAsPrimaryAction = true

        airPlayView.translatesAutoresizingMaskIntoConstraints = false
        airPlayContainer.translatesAutoresizingMaskIntoConstraints = false
        airPlayContainer.addSubview(airPlayView)
        // Same narrow-screen conflict as the transport/secondary buttons —
        // a hard `== 44` here left Auto Layout no room to shrink and forced
        // it to break an arbitrary constraint elsewhere in the row instead.
        let airPlayWidth = airPlayContainer.widthAnchor.constraint(equalToConstant: 44)
        let airPlayHeight = airPlayContainer.heightAnchor.constraint(equalToConstant: 44)
        airPlayWidth.priority = .required - 1
        airPlayHeight.priority = .required - 1
        NSLayoutConstraint.activate([
            airPlayView.leadingAnchor.constraint(equalTo: airPlayContainer.leadingAnchor),
            airPlayView.trailingAnchor.constraint(equalTo: airPlayContainer.trailingAnchor),
            airPlayView.topAnchor.constraint(equalTo: airPlayContainer.topAnchor),
            airPlayView.bottomAnchor.constraint(equalTo: airPlayContainer.bottomAnchor),
            airPlayWidth,
            airPlayHeight,
        ])

        let secondary = UIStackView(arrangedSubviews: [rateButton, UIView(), tocButton, sleepButton, airPlayContainer])
        secondary.axis = .horizontal
        secondary.alignment = .center
        secondary.spacing = 16

        volumeView.showsVolumeSlider = true
        volumeView.translatesAutoresizingMaskIntoConstraints = false

        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, UIView(), remainingLabel])
        timeRow.axis = .horizontal
        timeRow.alignment = .fill

        // `coverContainer` must NOT be an arranged subview directly: the
        // vertical stack's default `.fill` alignment pins every arranged
        // subview's leading/trailing to the stack's own edges (full width),
        // which unconditionally contradicts the explicit 0.7-multiplier
        // width + centerX constraints below — "Unable to simultaneously
        // satisfy constraints" on every single appearance, regardless of
        // device width. A plain full-width wrapper absorbs the stack's fill
        // pinning; `coverContainer` sizes itself against the wrapper instead.
        let coverRow = UIView()
        coverRow.translatesAutoresizingMaskIntoConstraints = false
        coverRow.addSubview(coverContainer)

        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(coverRow)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(authorLabel)
        stackView.addArrangedSubview(chapterLabel)
        stackView.addArrangedSubview(slider)
        stackView.addArrangedSubview(timeRow)
        stackView.addArrangedSubview(transport)
        stackView.addArrangedSubview(volumeView)
        stackView.addArrangedSubview(secondary)
        view.addSubview(stackView)
        view.bringSubviewToFront(dragHandle)
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(stackView)

        NSLayoutConstraint.activate([
            dragHandle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            dragHandle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 36),
            dragHandle.heightAnchor.constraint(equalToConstant: 5),

            closeButton.topAnchor.constraint(equalTo: dragHandle.bottomAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            stackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            coverContainer.widthAnchor.constraint(equalTo: coverRow.widthAnchor, multiplier: 0.7),
            coverContainer.heightAnchor.constraint(equalTo: coverContainer.widthAnchor, multiplier: 1.5),
            coverContainer.topAnchor.constraint(equalTo: coverRow.topAnchor),
            coverContainer.bottomAnchor.constraint(equalTo: coverRow.bottomAnchor),
            coverContainer.centerXAnchor.constraint(equalTo: coverRow.centerXAnchor),
            volumeView.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func bind() {
        [player.objectWillChange, playbackClock.objectWillChange, library.objectWillChange, playerPresentation.objectWillChange]
            .forEach { publisher in
                publisher
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] _ in self?.render() }
                    .store(in: &cancellables)
            }

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        positionTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.player.position {
                guard !Task.isCancelled else { break }
                if !self.isScrubbing {
                    await MainActor.run {
                        self.renderPlaybackPosition()
                    }
                }
            }
        }
    }

    private func configureTransportButton(
        _ button: UIButton,
        image: String,
        action: Selector,
        pointSize: CGFloat = 22
    ) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.tintColor = .label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        // 44pt is the HIG minimum tap target, but on a standard-width iPhone
        // five transport buttons (the 64pt play/pause icon alone needs more
        // than 44pt) cannot all satisfy it plus their minimum spacing at
        // once — that combination produced "Unable to simultaneously
        // satisfy constraints" every time the full player appeared. Priority
        // just below required lets Auto Layout shrink below 44pt on narrow
        // screens instead of throwing, while still holding 44pt whenever
        // there's room for it.
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        width.priority = .required - 1
        height.priority = .required - 1
        NSLayoutConstraint.activate([width, height])
    }

    private func configureSecondaryButton(
        _ button: UIButton,
        image: String,
        title: String?,
        action: Selector?
    ) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: image)
        config.title = title
        config.imagePadding = 6
        button.configuration = config
        button.tintColor = .label
        button.translatesAutoresizingMaskIntoConstraints = false
        if let action {
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        // See configureTransportButton: same narrow-screen conflict applies
        // to the secondary row (rate/TOC/sleep/AirPlay).
        let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
        let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        width.priority = .required - 1
        height.priority = .required - 1
        NSLayoutConstraint.activate([width, height])
    }

    private func render() {
        let currentBook = currentBookID.flatMap { id in
            library.books.first(where: { $0.id == id })
        }

        titleLabel.text = currentBook?.resolvedTitle ?? (player.snapshot?.bookTitle ?? L10n.string("player.audiobookFallback"))
        authorLabel.text = currentBook?.author
        authorLabel.isHidden = (authorLabel.text?.isEmpty ?? true)
        chapterLabel.text = player.snapshot == nil
            ? L10n.string("player.chapter", UserDefaults.standard.integer(forKey: AudioPlayer.currentChapterIndexDefaultsKey) + 1)
            : player.effectiveChapterTitle

        if let data = currentBook?.coverPNG, let image = UIImage(data: data) {
            coverImageView.image = image
            coverImageView.contentMode = .scaleAspectFill
        } else {
            coverImageView.image = UIImage(systemName: "headphones")
            coverImageView.contentMode = .scaleAspectFit
        }

        renderPlaybackPosition()
        renderPlayPauseButton()
        renderRateMenu()
        renderSleepMenu()
    }

    private func renderPlaybackPosition() {
        slider.maximumValue = Float(max(playbackClock.durationSeconds, 1))
        if !isScrubbing {
            slider.value = Float(playbackClock.positionSeconds)
        }
        elapsedLabel.text = formatTime(playbackClock.positionSeconds)
        let remaining = max(0, playbackClock.durationSeconds - playbackClock.positionSeconds)
        let rateAdjusted = remaining / Double(player.rate.rawValue)
        remainingLabel.text = "-" + formatTime(rateAdjusted)
    }

    private func renderPlayPauseButton() {
        if player.isLoading {
            playPauseButton.setImage(nil, for: .normal)
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            playPauseButton.configuration = nil
            playPauseButton.subviews.forEach { subview in
                if subview is UIActivityIndicatorView { subview.removeFromSuperview() }
            }
            spinner.translatesAutoresizingMaskIntoConstraints = false
            playPauseButton.addSubview(spinner)
            NSLayoutConstraint.activate([
                spinner.centerXAnchor.constraint(equalTo: playPauseButton.centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            ])
        } else {
            playPauseButton.subviews.forEach {
                if $0 is UIActivityIndicatorView { $0.removeFromSuperview() }
            }
            playPauseButton.setImage(
                UIImage(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill"),
                for: .normal
            )
            playPauseButton.imageView?.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .regular)
        }
        playPauseButton.accessibilityLabel = player.isPlaying
            ? L10n.string("player.pause")
            : L10n.string("player.play")
    }

    private func renderRateMenu() {
        var config = rateButton.configuration ?? UIButton.Configuration.plain()
        config.title = player.rate.shortLabel
        rateButton.configuration = config
        rateButton.menu = UIMenu(children: PlaybackRate.allCases.map { rate in
            UIAction(title: rate.shortLabel, state: rate == player.rate ? .on : .off) { [weak self] _ in
                self?.player.setRate(rate)
                self?.render()
            }
        })
    }

    private func renderSleepMenu() {
        let minutes = [0, 5, 15, 30, 45, 60]
        sleepButton.menu = UIMenu(children: minutes.map { minute in
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
        sleepButton.accessibilityLabel = L10n.string("player.sleepTimer")
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
            slider, volumeView, airPlayContainer,
            previousChapterButton, skipBackButton, playPauseButton, skipForwardButton, nextChapterButton,
            rateButton, tocButton, sleepButton,
        ]
    }

    @objc
    private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .changed:
            // Only downward drags are meaningful — there's nowhere "more
            // full" to go, so upward translation is clamped to zero.
            let clampedY = max(0, translation.y)
            view.transform = CGAffineTransform(translationX: 0, y: clampedY)

        case .ended, .cancelled:
            let dismissDistanceThreshold: CGFloat = 120
            let dismissVelocityThreshold: CGFloat = 800
            let shouldDismiss = translation.y > dismissDistanceThreshold || velocity.y > dismissVelocityThreshold

            guard shouldDismiss else {
                resetTransformToIdentity(animated: !UIAccessibility.isReduceMotionEnabled, velocity: velocity.y)
                return
            }

            if UIAccessibility.isReduceMotionEnabled {
                // Snap instead of sliding when the user has asked for less
                // motion — the dismissal itself still happens immediately.
                view.transform = .identity
                playerPresentation.dismissFullPlayer()
            } else {
                UIView.animate(
                    withDuration: 0.25,
                    delay: 0,
                    options: [.curveEaseIn],
                    animations: {
                        self.view.transform = CGAffineTransform(translationX: 0, y: self.view.bounds.height)
                    },
                    completion: { [weak self] _ in
                        guard let self else { return }
                        self.playerPresentation.dismissFullPlayer()
                        // `IOSRootContainer.refreshOverlayState()` only toggles
                        // isHidden/alpha and never resets transform, so this
                        // view must restore its own resting transform here —
                        // otherwise it reappears off-screen next time it's shown.
                        self.view.transform = .identity
                    }
                )
            }

        default:
            break
        }
    }

    private func resetTransformToIdentity(animated: Bool, velocity: CGFloat) {
        guard animated else {
            view.transform = .identity
            return
        }
        UIView.animate(
            withDuration: 0.3,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: abs(velocity) / 1000,
            options: [.allowUserInteraction],
            animations: {
                self.view.transform = .identity
            }
        )
    }

    @objc
    private func previousChapterTapped() {
        player.previousChapter()
        render()
    }

    @objc
    private func skipBackTapped() {
        player.skipBackward(seconds: 15)
        render()
    }

    @objc
    private func playPauseTapped() {
        player.togglePlayPause()
        render()
    }

    @objc
    private func skipForwardTapped() {
        player.skipForward(seconds: 15)
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
        elapsedLabel.text = formatTime(TimeInterval(slider.value))
    }

    @objc
    private func scrubEnded() {
        isScrubbing = false
        player.seek(to: TimeInterval(slider.value))
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
                onDownload: nil,
                onDownloadAll: nil,
                onCancelDownloads: nil,
                onClearDownloads: nil
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

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return unsafe String(format: "%d:%02d:%02d", h, m, s) }
        return unsafe String(format: "%d:%02d", m, s)
    }
}

extension FullPlayerScreenController: UIGestureRecognizerDelegate {
    /// Rejects touches that land on the scrubber, transport buttons, volume
    /// slider, or AirPlay button so `dismissPanGesture` never competes with
    /// their own gesture/target-action handling — only `dismissPanGesture`
    /// itself is filtered here; any other recognizer is left untouched.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === dismissPanGesture else { return true }
        let location = touch.location(in: view)
        for control in nonDraggableViews where !control.isHidden {
            let frameInView = control.convert(control.bounds, to: view)
            if frameInView.contains(location) {
                return false
            }
        }
        return true
    }
}

private extension UIFont {
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
