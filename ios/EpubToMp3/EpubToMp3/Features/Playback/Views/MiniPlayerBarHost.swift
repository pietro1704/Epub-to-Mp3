#if os(iOS)
import Combine
import UIKit

enum MiniPlayerLayoutMetrics {
    static let contentHeight: CGFloat = 112
    static let maximumBottomSafeAreaInset: CGFloat = 44
    /// Keeps the transport, chapter seek bar, and labels above the bottom
    /// safe area on iPhone.
    static let maximumOverlayHeight = contentHeight + maximumBottomSafeAreaInset
}

@MainActor
final class MiniPlayerBarUIKitView: UIView, UIGestureRecognizerDelegate {
    /// Reserved only for system-managed accessories. The reader's safe area
    /// must keep its own background beneath the floating mini-player pill.
    private let bottomSafeAreaFill = AdaptiveMaterialView()
    private let materialView = AdaptiveMaterialView()
    private let coverView = UIImageView()
    private let titleLabel = UILabel()
    private let chapterLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let skipBackButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let rateButton = UIButton(type: .system)
    private let progressSlider = CompactSlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let chromeStack = UIStackView()
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var isScrubbing = false

    private var player: AudioPlayer?
    private var playbackClock: PlaybackClock?
    private var library: LibraryStore?
    private var onTap: (() -> Void)?
    private var onPlayRequested: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private let usesSystemManagedBottomInset: Bool

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: MiniPlayerLayoutMetrics.contentHeight
                + (usesSystemManagedBottomInset
                    ? 0
                    : min(safeAreaInsets.bottom, MiniPlayerLayoutMetrics.maximumBottomSafeAreaInset))
        )
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        minimumHeightConstraint?.constant = intrinsicContentSize.height
        invalidateIntrinsicContentSize()
    }

    override init(frame: CGRect) {
        usesSystemManagedBottomInset = false
        super.init(frame: frame)
        configureView()
    }

    init(usesSystemManagedBottomInset: Bool) {
        self.usesSystemManagedBottomInset = usesSystemManagedBottomInset
        super.init(frame: .zero)
        configureView()
    }

    private func configureView() {
        preservesSuperviewLayoutMargins = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        backgroundColor = .clear
        layer.cornerCurve = .continuous
        clipsToBounds = true
        // The root container pins the player only by its bottom edge while
        // the reader owns the remaining space. Make this view's intrinsic
        // content height non-negotiable so the reader cannot compress the
        // 44-point controls below the screen edge.
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: intrinsicContentSize.height)
        minimumHeight.priority = .required
        minimumHeight.isActive = true
        minimumHeightConstraint = minimumHeight
        bottomSafeAreaFill.accessibilityIdentifier = "miniPlayer.bottomSafeAreaFill"
        bottomSafeAreaFill.isHidden = true
        addSubview(bottomSafeAreaFill)
        addSubview(materialView)
        materialView.accessibilityIdentifier = "miniPlayer.pillMaterial"
        materialView.layer.cornerRadius = 20
        materialView.clipsToBounds = true
        let expandTap = UITapGestureRecognizer(target: self, action: #selector(openTapped))
        expandTap.delegate = self
        expandTap.cancelsTouchesInView = false
        addGestureRecognizer(expandTap)
        NSLayoutConstraint.activate([
            bottomSafeAreaFill.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSafeAreaFill.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSafeAreaFill.topAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            bottomSafeAreaFill.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(
                equalTo: usesSystemManagedBottomInset ? bottomAnchor : safeAreaLayoutGuide.bottomAnchor
            ),
        ])

        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 10
        coverView.backgroundColor = .tertiarySystemFill
        NSLayoutConstraint.activate([
            coverView.widthAnchor.constraint(equalToConstant: 36),
            coverView.heightAnchor.constraint(equalToConstant: 36),
        ])

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1

        chapterLabel.font = .preferredFont(forTextStyle: .caption2)
        chapterLabel.adjustsFontForContentSizeCategory = true
        chapterLabel.numberOfLines = 1
        chapterLabel.textColor = .secondaryLabel

        let labels = UIStackView(arrangedSubviews: [titleLabel, chapterLabel])
        labels.axis = .vertical
        labels.spacing = 2

        openButton.accessibilityIdentifier = "miniPlayer.open"
        openButton.accessibilityLabel = L10n.string("player.openFullPlayer")
        openButton.accessibilityHint = L10n.string("player.openFullPlayerHint")
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        openButton.addSubview(coverView)
        openButton.addSubview(labels)
        labels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: 8),
            coverView.topAnchor.constraint(equalTo: openButton.topAnchor, constant: 4),
            coverView.bottomAnchor.constraint(equalTo: openButton.bottomAnchor, constant: -4),
            labels.leadingAnchor.constraint(equalTo: coverView.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: openButton.trailingAnchor),
            labels.centerYAnchor.constraint(equalTo: openButton.centerYAnchor),
            openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        playPauseButton.tintColor = .label
        playPauseButton.accessibilityIdentifier = "miniPlayer.playPause"
        playPauseButton.accessibilityLabel = L10n.string("player.play")
        previousButton.tintColor = .label
        previousButton.accessibilityIdentifier = "miniPlayer.previous"
        previousButton.accessibilityLabel = L10n.string("player.previousChapter")
        skipBackButton.tintColor = .label
        skipBackButton.accessibilityIdentifier = "miniPlayer.skipBack"
        nextButton.tintColor = .label
        nextButton.accessibilityIdentifier = "miniPlayer.next"
        nextButton.accessibilityLabel = L10n.string("player.nextChapter")
        skipForwardButton.tintColor = .label
        skipForwardButton.accessibilityIdentifier = "miniPlayer.skipForward"
        rateButton.tintColor = .label
        rateButton.accessibilityIdentifier = "miniPlayer.rate"
        rateButton.accessibilityLabel = L10n.string("player.speed")
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        skipBackButton.addTarget(self, action: #selector(skipBackTapped), for: .touchUpInside)
        skipForwardButton.addTarget(self, action: #selector(skipForwardTapped), for: .touchUpInside)
        for button in [playPauseButton, previousButton, skipBackButton, nextButton, skipForwardButton, rateButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        previousButton.setImage(UIImage(systemName: "backward.end.fill"), for: .normal)
        nextButton.setImage(UIImage(systemName: "forward.end.fill"), for: .normal)
        progressSlider.accessibilityIdentifier = "miniPlayer.progress"
        progressSlider.accessibilityLabel = L10n.string("player.playbackPosition")
        progressSlider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        progressSlider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        progressSlider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        progressSlider.addTarget(self, action: #selector(scrubEnded), for: .editingDidEnd)
        [elapsedLabel, remainingLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            $0.textColor = .secondaryLabel
        }
        elapsedLabel.accessibilityIdentifier = "miniPlayer.elapsed"
        remainingLabel.accessibilityIdentifier = "miniPlayer.remaining"

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let trailingStack = UIStackView(arrangedSubviews: [previousButton, skipBackButton, playPauseButton, spinner, skipForwardButton, nextButton, rateButton])
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 4

        chromeStack.axis = .horizontal
        chromeStack.alignment = .center
        chromeStack.spacing = 12
        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        chromeStack.addArrangedSubview(openButton)
        chromeStack.addArrangedSubview(trailingStack)
        let timeRow = UIStackView(arrangedSubviews: [elapsedLabel, UIView(), remainingLabel])
        timeRow.axis = .horizontal
        timeRow.alignment = .center
        let playbackStack = UIStackView(arrangedSubviews: [chromeStack, progressSlider, timeRow])
        playbackStack.axis = .vertical
        playbackStack.alignment = .fill
        playbackStack.spacing = 0
        playbackStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playbackStack)
        bringSubviewToFront(playbackStack)

        NSLayoutConstraint.activate([
            playbackStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            playbackStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            playbackStack.centerYAnchor.constraint(equalTo: materialView.centerYAnchor),
            playbackStack.topAnchor.constraint(greaterThanOrEqualTo: materialView.topAnchor, constant: 3),
            playbackStack.bottomAnchor.constraint(lessThanOrEqualTo: materialView.bottomAnchor, constant: -3),
        ])
        updateTypographyForContentSizeCategory()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void,
        onPlayRequested: @escaping () -> Void = {}
    ) {
        self.player = player
        self.playbackClock = playbackClock
        self.library = library
        self.onTap = onTap
        self.onPlayRequested = onPlayRequested
        bindIfNeeded(player: player, playbackClock: playbackClock, library: library)
        rebuildRateMenu(player: player)
        render()
    }

    func applyReaderBackground(_ color: UIColor) {
        backgroundColor = color
        bottomSafeAreaFill.backgroundColor = color
    }

    private func bindIfNeeded(player: AudioPlayer, playbackClock: PlaybackClock, library: LibraryStore) {
        guard cancellables.isEmpty else { return }
        player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        playbackClock.$snapshot
            .sink { [weak self] snapshot in self?.renderPlaybackPosition(snapshot) }
            .store(in: &cancellables)
        library.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    static func activeBookID(defaults: UserDefaults = .standard) -> String? {
        // The reader is the user's newest explicit book selection. It must
        // win over a persisted playback pointer so the compact player does
        // not keep showing a previously opened book while the reader is
        // already displaying a different one.
        defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
            ?? defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
    }

    private func render() {
        guard let player, let library else { return }
        let currentBookID = Self.activeBookID()
        let book = currentBookID.flatMap { id in library.books.first(where: { $0.id == id }) }
        titleLabel.text = player.effectiveChapterTitle
        chapterLabel.text = book?.resolvedTitle ?? L10n.string("player.audiobookFallback")
        openButton.accessibilityValue = [titleLabel.text, chapterLabel.text]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")

        if let data = book?.coverPNG, let image = UIImage(data: data) {
            coverView.image = image
        } else {
            coverView.image = UIImage(systemName: "book.closed")
            coverView.tintColor = .tintColor
            coverView.contentMode = .scaleAspectFit
        }

        let isLoading = player.isLoading
        if isLoading {
            spinner.startAnimating()
            playPauseButton.isHidden = true
        } else {
            spinner.stopAnimating()
            playPauseButton.isHidden = false
        }

        let playPauseName = player.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: playPauseName), for: .normal)
        playPauseButton.accessibilityLabel = player.isPlaying
            ? L10n.string("player.pause")
            : L10n.string("player.play")
        rateButton.setTitle(player.rate.shortLabel, for: .normal)
        updateSkipButton(skipBackButton, seconds: Self.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey), forward: false)
        updateSkipButton(skipForwardButton, seconds: Self.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey), forward: true)
        renderPlaybackPosition()
        accessibilityIdentifier = "miniPlayer.bar"
    }

    private static func configuredSkipInterval(forKey key: String) -> Int {
        let value = UserDefaults.standard.object(forKey: key) as? Double ?? 15
        return AppSettings.playbackSkipIntervals.contains(value) ? Int(value) : 15
    }

    private func updateSkipButton(_ button: UIButton, seconds: Int, forward: Bool) {
        let symbol = forward ? "goforward" : "gobackward"
        button.setImage(UIImage(systemName: "\(symbol).\(seconds)"), for: .normal)
        button.accessibilityLabel = L10n.string(
            forward ? "player.skipForward.seconds" : "player.skipBack.seconds",
            seconds
        )
    }

    private func renderPlaybackPosition(_ clockSnapshot: PlaybackClock.Snapshot? = nil) {
        guard let player, let playbackClock else { return }
        let snapshot = clockSnapshot ?? playbackClock.snapshot
        let position = player.isSeeking ? player.positionSeconds : snapshot.positionSeconds
        let duration = snapshot.durationSeconds
        progressSlider.maximumValue = Float(max(duration, 1))
        if !isScrubbing && !player.isSeeking {
            progressSlider.value = Float(position)
        }
        elapsedLabel.text = formatTime(position)
        remainingLabel.text = "−\(formatTime(max(0, duration - position) / Double(player.rate.rawValue)))"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    func refresh() {
        render()
    }

    private func rebuildRateMenu(player: AudioPlayer) {
        rateButton.showsMenuAsPrimaryAction = true
        rateButton.menu = UIMenu(children: PlaybackRate.allCases.map { rate in
            UIAction(
                title: rate.shortLabel,
                state: rate == player.rate ? .on : .off
            ) { [weak player] _ in
                player?.setRate(rate)
            }
        })
    }

    @objc
    private func openTapped() {
        onTap?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var current: UIView? = touch.view
        while let view = current {
            // The whole pill opens the full player. Only the playback
            // controls remain exempt so tapping play/next/rate keeps its
            // local action instead of expanding the player.
            if view === playPauseButton || view === previousButton || view === skipBackButton
                || view === nextButton || view === skipForwardButton || view === rateButton || view === progressSlider {
                return false
            }
            current = view.superview
        }
        return true
    }

    @objc
    private func playPauseTapped() {
        guard let player else { return }
        // A newly opened reader intentionally has no AVQueuePlayer yet.
        // Its play control must begin the local conversion instead of merely
        // arming an intent that no producer will ever consume.
        if player.hasLoadedAudioQueue || player.isConverting || player.snapshot?.playableChapters.isEmpty == false {
            if let presenter = nearestViewController() {
                ReaderPlaybackTapHandler.handle(player: player, presenting: presenter)
            } else {
                player.togglePlayPause()
            }
        } else {
            onPlayRequested?()
        }
        render()
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    @objc
    private func previousTapped() {
        player?.previousChapter()
        render()
    }

    @objc
    private func nextTapped() {
        player?.nextChapter()
        render()
    }

    @objc
    private func skipBackTapped() {
        player?.skipBackward()
        render()
    }

    @objc
    private func skipForwardTapped() {
        player?.skipForward()
        render()
    }

    @objc
    private func scrubBegan() {
        isScrubbing = true
    }

    @objc
    private func scrubChanged() {
        elapsedLabel.text = formatTime(TimeInterval(progressSlider.value))
    }

    @objc
    private func scrubEnded() {
        isScrubbing = false
        player?.seek(to: TimeInterval(progressSlider.value))
        render()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else {
            return
        }
        updateTypographyForContentSizeCategory()
    }

    private func updateTypographyForContentSizeCategory() {
        // The global player must stay compact. At accessibility sizes the
        // primary chapter title remains visible while VoiceOver still exposes
        // the complete chapter and book metadata through the open button.
        chapterLabel.isHidden = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    }
}
#endif
