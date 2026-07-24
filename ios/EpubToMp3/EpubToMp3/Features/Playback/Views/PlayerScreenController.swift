#if os(iOS)
import Combine
import UIKit
import MediaPlayer

@MainActor
final class PlayerScreenController: UIViewController {
    private var snapshot: JobSnapshot
    private var backendBaseURL: URL?
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock

    private let artworkView = UIImageView()
    private let titleLabel = UILabel()
    private let chapterLabel = UILabel()
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let durationLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let playPauseButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let rateButton = UIButton(type: .system)
    private let volumeView = MPVolumeView(frame: .zero)
    private var cancellables: Set<AnyCancellable> = []

    init(snapshot: JobSnapshot, backendBaseURL: URL?, player: AudioPlayer, playbackClock: PlaybackClock) {
        self.snapshot = snapshot
        self.backendBaseURL = backendBaseURL
        self.player = player
        self.playbackClock = playbackClock
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("reader.nowPlaying")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: L10n.string("player.close"),
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )
        buildUI()
        bindState()
        if player.snapshot?.jobId != snapshot.jobId {
            player.backendBaseURL = backendBaseURL
            player.play(snapshot: snapshot, startingAt: 0)
        }
        render()
    }

    func update(snapshot: JobSnapshot, backendBaseURL: URL?) {
        self.snapshot = snapshot
        self.backendBaseURL = backendBaseURL
        render()
    }

    private func buildUI() {
        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.backgroundColor = .tintColor.withAlphaComponent(0.15)
        artworkView.tintColor = .tintColor
        artworkView.image = UIImage(systemName: "headphones")
        artworkView.contentMode = .scaleAspectFit
        artworkView.layer.cornerRadius = 24
        artworkView.clipsToBounds = true

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 1
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        chapterLabel.font = .preferredFont(forTextStyle: .subheadline)
        chapterLabel.textColor = .secondaryLabel
        chapterLabel.numberOfLines = 2
        chapterLabel.textAlignment = .center
        chapterLabel.translatesAutoresizingMaskIntoConstraints = false

        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderCommit), for: [.touchUpInside, .touchUpOutside])

        [elapsedLabel, durationLabel].forEach {
            $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            $0.textColor = .secondaryLabel
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        previousButton.setImage(UIImage(systemName: "backward.fill"), for: .normal)
        playPauseButton.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        nextButton.setImage(UIImage(systemName: "forward.fill"), for: .normal)
        [previousButton, playPauseButton, nextButton, rateButton].forEach {
            $0.tintColor = .label
            $0.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                $0.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
        }
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        playPauseButton.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        volumeView.showsVolumeSlider = true
        volumeView.translatesAutoresizingMaskIntoConstraints = false

        let transport = UIStackView(arrangedSubviews: [previousButton, playPauseButton, nextButton])
        transport.axis = .horizontal
        transport.alignment = .center
        transport.distribution = .equalSpacing
        transport.translatesAutoresizingMaskIntoConstraints = false

        let times = UIStackView(arrangedSubviews: [elapsedLabel, UIView(), durationLabel])
        times.axis = .horizontal
        times.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [
            artworkView,
            titleLabel,
            chapterLabel,
            slider,
            times,
            transport,
            rateButton,
            volumeView,
        ])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            artworkView.widthAnchor.constraint(equalToConstant: 220),
            artworkView.heightAnchor.constraint(equalToConstant: 220),
        ])
    }

    private func bindState() {
        player.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)

        playbackClock.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render() }
            .store(in: &cancellables)
    }

    private func render() {
        let activeSnapshot: JobSnapshot
        if let playerSnapshot = player.snapshot, playerSnapshot.jobId == snapshot.jobId {
            activeSnapshot = playerSnapshot
        } else {
            activeSnapshot = snapshot
        }

        titleLabel.text = activeSnapshot.bookTitle ?? L10n.string("player.audiobookFallback")
        chapterLabel.text = player.snapshot == nil ? "—" : player.effectiveChapterTitle
        slider.maximumValue = Float(max(playbackClock.durationSeconds, 1))
        slider.value = Float(playbackClock.positionSeconds)
        elapsedLabel.text = format(seconds: AudioPlayer.rateAdjustedDuration(
            seconds: playbackClock.positionSeconds,
            rate: player.rate
        ))
        durationLabel.text = format(seconds: AudioPlayer.rateAdjustedDuration(
            seconds: playbackClock.durationSeconds,
            rate: player.rate
        ))
        playPauseButton.setImage(
            UIImage(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill"),
            for: .normal
        )
        updateRateMenu()
    }

    private func updateRateMenu() {
        rateButton.setTitle(player.rate.shortLabel, for: .normal)
        rateButton.showsMenuAsPrimaryAction = true
        rateButton.menu = UIMenu(children: PlaybackRate.allCases.map { rate in
            UIAction(title: rate.shortLabel, state: rate == player.rate ? .on : .off) { [weak self] _ in
                self?.player.setRate(rate)
                self?.render()
            }
        })
    }

    @objc
    private func closeTapped() {
        player.pause()
        dismiss(animated: true)
    }

    @objc
    private func previousTapped() {
        player.previousChapter()
        render()
    }

    @objc
    private func playPauseTapped() {
        player.togglePlayPause()
        render()
    }

    @objc
    private func nextTapped() {
        player.nextChapter()
        render()
    }

    @objc
    private func sliderChanged() {
        elapsedLabel.text = format(seconds: TimeInterval(slider.value))
    }

    @objc
    private func sliderCommit() {
        player.seek(to: TimeInterval(slider.value))
        render()
    }

    private func format(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
#endif
