#if os(iOS)
import Combine
import UIKit

enum MiniPlayerLayoutMetrics {
    static let contentHeight: CGFloat = 52
    static let maximumBottomSafeAreaInset: CGFloat = 44
    /// Keeps the overlay compact while allowing the 52-point controls and a
    /// large iPhone bottom safe-area inset.
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
    private let nextButton = UIButton(type: .system)
    private let rateButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let chromeStack = UIStackView()
    private var minimumHeightConstraint: NSLayoutConstraint?

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
        nextButton.tintColor = .label
        nextButton.accessibilityIdentifier = "miniPlayer.next"
        nextButton.accessibilityLabel = L10n.string("player.nextChapter")
        rateButton.tintColor = .label
        rateButton.accessibilityIdentifier = "miniPlayer.rate"
        rateButton.accessibilityLabel = L10n.string("player.speed")
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        for button in [playPauseButton, nextButton, rateButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        nextButton.setImage(UIImage(systemName: "forward.end.fill"), for: .normal)

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let trailingStack = UIStackView(arrangedSubviews: [playPauseButton, spinner, nextButton, rateButton])
        trailingStack.axis = .horizontal
        trailingStack.alignment = .center
        trailingStack.spacing = 4

        chromeStack.axis = .horizontal
        chromeStack.alignment = .center
        chromeStack.spacing = 12
        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        chromeStack.addArrangedSubview(openButton)
        chromeStack.addArrangedSubview(trailingStack)
        addSubview(chromeStack)
        bringSubviewToFront(chromeStack)

        NSLayoutConstraint.activate([
            chromeStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            chromeStack.centerYAnchor.constraint(equalTo: materialView.centerYAnchor),
            chromeStack.topAnchor.constraint(greaterThanOrEqualTo: materialView.topAnchor, constant: 4),
            chromeStack.bottomAnchor.constraint(lessThanOrEqualTo: materialView.bottomAnchor, constant: -4),
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
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        playbackClock.objectWillChange
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
        library.objectWillChange
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
        accessibilityIdentifier = "miniPlayer.bar"
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
            if view === playPauseButton || view === nextButton || view === rateButton {
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
            player.togglePlayPause()
        } else {
            onPlayRequested?()
        }
        render()
    }

    @objc
    private func nextTapped() {
        player?.nextChapter()
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
