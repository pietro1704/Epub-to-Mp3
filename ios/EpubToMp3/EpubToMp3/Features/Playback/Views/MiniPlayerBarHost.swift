#if os(iOS)
import Combine
import UIKit

@MainActor
final class MiniPlayerBarUIKitView: UIView {
    private let materialView = AdaptiveMaterialView()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let coverView = UIImageView()
    private let titleLabel = UILabel()
    private let chapterLabel = UILabel()
    private let openButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let rateButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let chromeStack = UIStackView()

    private var player: AudioPlayer?
    private var playbackClock: PlaybackClock?
    private var library: LibraryStore?
    private var onTap: (() -> Void)?
    private var cancellables: Set<AnyCancellable> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        preservesSuperviewLayoutMargins = true
        backgroundColor = .clear
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addSubview(materialView)
        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        progressView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressView)

        coverView.translatesAutoresizingMaskIntoConstraints = false
        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 6
        coverView.backgroundColor = .tertiarySystemFill
        NSLayoutConstraint.activate([
            coverView.widthAnchor.constraint(equalToConstant: 44),
            coverView.heightAnchor.constraint(equalToConstant: 44),
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

        openButton.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        openButton.accessibilityIdentifier = "miniPlayer.open"
        openButton.accessibilityLabel = L10n.string("player.openFullPlayer")
        openButton.accessibilityHint = L10n.string("player.openFullPlayerHint")
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.addSubview(coverView)
        openButton.addSubview(labels)
        labels.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            coverView.leadingAnchor.constraint(equalTo: openButton.leadingAnchor),
            coverView.topAnchor.constraint(equalTo: openButton.topAnchor),
            coverView.bottomAnchor.constraint(equalTo: openButton.bottomAnchor),
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
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.topAnchor.constraint(equalTo: topAnchor),
            chromeStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            chromeStack.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 8),
            chromeStack.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        library: LibraryStore,
        onTap: @escaping () -> Void
    ) {
        self.player = player
        self.playbackClock = playbackClock
        self.library = library
        self.onTap = onTap
        bindIfNeeded(player: player, playbackClock: playbackClock, library: library)
        rebuildRateMenu(player: player)
        render()
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

    private func render() {
        guard let player, let playbackClock, let library else { return }
        let currentBookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
        let book = currentBookID.flatMap { id in library.books.first(where: { $0.id == id }) }
        titleLabel.text = book?.resolvedTitle ?? L10n.string("player.audiobookFallback")
        chapterLabel.text = player.snapshot == nil
            ? L10n.string("player.chapter", UserDefaults.standard.integer(forKey: AudioPlayer.currentChapterIndexDefaultsKey) + 1)
            : player.effectiveChapterTitle

        if let data = book?.coverPNG, let image = UIImage(data: data) {
            coverView.image = image
        } else {
            coverView.image = UIImage(systemName: "book.closed")
            coverView.tintColor = .tintColor
            coverView.contentMode = .scaleAspectFit
        }

        let progress: Float
        if player.isConverting {
            progress = Float(player.conversionProgress ?? 0)
            progressView.progressTintColor = .systemOrange
        } else if playbackClock.durationSeconds > 0 {
            progress = Float(min(1, max(0, playbackClock.positionSeconds / playbackClock.durationSeconds)))
            progressView.progressTintColor = tintColor
        } else {
            progress = 0
            progressView.progressTintColor = tintColor
        }
        progressView.progress = progress

        let isLoading = player.isConverting && !player.firstChapterReady
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

    @objc
    private func playPauseTapped() {
        player?.togglePlayPause()
        render()
    }

    @objc
    private func nextTapped() {
        player?.nextChapter()
        render()
    }
}
#endif
