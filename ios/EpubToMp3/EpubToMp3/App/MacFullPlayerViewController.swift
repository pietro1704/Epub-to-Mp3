#if os(macOS)
import AppKit
import Combine

@MainActor
final class MacFullPlayerViewController: NSViewController {
    private let player: AudioPlayer
    private let library: LibraryStore
    private let presentation: PlayerPresentation
    private let onStartPlayback: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let coverView = NSImageView()
    private let playButton = NSButton()
    private let playSpinner = NSProgressIndicator()
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")
    private var cancellable: AnyCancellable?

    init(player: AudioPlayer, library: LibraryStore, presentation: PlayerPresentation, onStartPlayback: @escaping () -> Void) {
        self.player = player
        self.library = library
        self.presentation = presentation
        self.onStartPlayback = onStartPlayback
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 10
        coverView.layer?.masksToBounds = true
        coverView.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, statusLabel].forEach {
            $0.maximumNumberOfLines = 0
            $0.lineBreakMode = .byWordWrapping
            $0.cell?.wraps = true
            $0.cell?.isScrollable = false
        }
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("fullPlayer.chapterAndVoice")
        statusLabel.alignment = .center
        elapsedLabel.textColor = .secondaryLabelColor
        remainingLabel.textColor = .secondaryLabelColor
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged(_:))
        progressSlider.isContinuous = false
        progressSlider.setAccessibilityLabel(L10n.string("player.playbackPosition"))
        progressSlider.setAccessibilityIdentifier("fullPlayer.progress")
        elapsedLabel.setAccessibilityIdentifier("fullPlayer.elapsed")
        remainingLabel.setAccessibilityIdentifier("fullPlayer.remaining")
        playButton.imagePosition = .imageOnly
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playSpinner.style = .spinning
        playSpinner.isDisplayedWhenStopped = false
        playSpinner.controlSize = .regular
        let timeControls = NSStackView(views: [elapsedLabel, progressSlider, remainingLabel])
        timeControls.orientation = .horizontal
        timeControls.alignment = .centerY
        timeControls.spacing = 10
        let previous = NSButton(image: NSImage(systemSymbolName: "backward.end.fill", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(previousChapter))
        let next = NSButton(image: NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(nextChapter))
        previous.setAccessibilityIdentifier("fullPlayer.previousChapter")
        previous.setAccessibilityLabel(L10n.string("player.previousChapter"))
        previous.toolTip = L10n.string("player.previousChapter")
        next.setAccessibilityIdentifier("fullPlayer.nextChapter")
        next.setAccessibilityLabel(L10n.string("player.nextChapter"))
        next.toolTip = L10n.string("player.nextChapter")
        playButton.setAccessibilityIdentifier("fullPlayer.playPause")
        let close = NSButton(title: L10n.string("common.close"), target: self, action: #selector(closePlayer))
        let playControls = NSStackView(views: [playButton, playSpinner])
        playControls.orientation = .horizontal
        playControls.alignment = .centerY
        let controls = NSStackView(views: [previous, playControls, next])
        controls.spacing = 12
        controls.alignment = .centerY
        let content = NSStackView(views: [coverView, titleLabel, statusLabel, timeControls, controls, close])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        MacScrollableStack.install(content, in: background, maximumWidth: 480)
        let preferredCover = coverView.widthAnchor.constraint(equalToConstant: 280)
        preferredCover.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredCover,
            coverView.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            coverView.heightAnchor.constraint(equalTo: coverView.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            timeControls.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        view = background
        cancellable = player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let book = bookID.flatMap { id in library.books.first(where: { $0.id == id }) }
        titleLabel.stringValue = player.snapshot?.bookTitle ?? book?.resolvedTitle ?? L10n.string("player.nothingPlaying")
        coverView.image = book?.coverPNG.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        statusLabel.stringValue = player.isConverting
            ? L10n.string("player.preparingAudio")
            : (player.snapshot == nil ? L10n.string("player.nothingPlaying") : player.effectiveChapterTitle)
        if let voice = player.snapshot?.activeVoiceDisplayName { statusLabel.stringValue += "\n" + voice }
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playButton.setAccessibilityLabel(L10n.string(player.isPlaying ? "player.pause" : "player.play"))
        playButton.toolTip = L10n.string(player.isPlaying ? "player.pause" : "player.play")
        playButton.isHidden = player.isLoading
        if player.isLoading { playSpinner.startAnimation(nil) } else { playSpinner.stopAnimation(nil) }
        playButton.isEnabled = player.snapshot != nil || bookID != nil
        let duration = max(player.durationSeconds, 1)
        progressSlider.maxValue = duration
        progressSlider.doubleValue = min(player.playbackPositionSeconds, duration)
        progressSlider.isEnabled = player.durationSeconds > 0
        elapsedLabel.stringValue = Self.formatTime(player.playbackPositionSeconds)
        remainingLabel.stringValue = "−" + Self.formatTime(max(0, player.durationSeconds - player.playbackPositionSeconds))
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func progressChanged(_ sender: NSSlider) {
        player.seek(to: sender.doubleValue)
        refresh()
    }

    @objc private func togglePlayback() {
        if player.isPlaying { player.pause() } else { onStartPlayback() }
        refresh()
    }
    @objc private func previousChapter() { player.previousChapter() }
    @objc private func nextChapter() { player.nextChapter() }
    @objc private func closePlayer() { presentation.dismissFullPlayer() }
}

#endif
