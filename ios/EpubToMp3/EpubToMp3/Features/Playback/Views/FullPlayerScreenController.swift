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
    // `MPVolumeView.showsRouteButton`/`showsVolumeSlider` are deprecated
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
        let background = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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
        rateButton.showsMenuAsPrimaryAction = true

        configureSecondaryButton(tocButton, image: "list.bullet", title: nil, action: #selector(tocTapped))
        configureSecondaryButton(sleepButton, image: "moon.zzz", title: nil, action: nil)
        sleepButton.showsMenuAsPrimaryAction = true

        airPlayView.translatesAutoresizingMaskIntoConstraints = false
        airPlayContainer.translatesAutoresizingMaskIntoConstraints = false
        airPlayContainer.addSubview(airPlayView)
        NSLayoutConstraint.activate([
            airPlayView.leadingAnchor.constraint(equalTo: airPlayContainer.leadingAnchor),
            airPlayView.trailingAnchor.constraint(equalTo: airPlayContainer.trailingAnchor),
            airPlayView.topAnchor.constraint(equalTo: airPlayContainer.topAnchor),
            airPlayView.bottomAnchor.constraint(equalTo: airPlayContainer.bottomAnchor),
            airPlayContainer.widthAnchor.constraint(equalToConstant: 44),
            airPlayContainer.heightAnchor.constraint(equalToConstant: 44),
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

        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(coverContainer)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(authorLabel)
        stackView.addArrangedSubview(chapterLabel)
        stackView.addArrangedSubview(slider)
        stackView.addArrangedSubview(timeRow)
        stackView.addArrangedSubview(transport)
        stackView.addArrangedSubview(volumeView)
        stackView.addArrangedSubview(secondary)
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            stackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stackView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            coverContainer.widthAnchor.constraint(equalTo: stackView.widthAnchor, multiplier: 0.7),
            coverContainer.heightAnchor.constraint(equalTo: coverContainer.widthAnchor, multiplier: 1.5),
            volumeView.heightAnchor.constraint(equalToConstant: 34),
        ])
        coverContainer.centerXAnchor.constraint(equalTo: stackView.centerXAnchor).isActive = true
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
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
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
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
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
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) ?? fontDescriptor
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
