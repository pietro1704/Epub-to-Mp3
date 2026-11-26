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
    private let onGoToReading: (String) -> Void
    private let skipBackButton = NSButton()
    private let skipForwardButton = NSButton()
    private let ratePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sleepPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let contentsButton = NSButton()
    private let goToReadingButton = NSButton()
    private static let sleepMinutes = [0, 5, 15, 30, 45, 60]
    private let progressSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "-0:00")
    private var cancellable: AnyCancellable?
    private var clockCancellable: AnyCancellable?
    private var pairingCancellable: AnyCancellable?

    init(player: AudioPlayer, library: LibraryStore, presentation: PlayerPresentation, onStartPlayback: @escaping () -> Void,
         onGoToReading: @escaping (String) -> Void = { _ in }) {
        self.onGoToReading = onGoToReading
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
        statusLabel.textColor = .readableSecondaryLabel
        statusLabel.setAccessibilityIdentifier("fullPlayer.chapterAndVoice")
        statusLabel.alignment = .center
        elapsedLabel.textColor = .readableSecondaryLabel
        remainingLabel.textColor = .readableSecondaryLabel
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
        previous.bezelStyle = .texturedRounded
        next.bezelStyle = .texturedRounded
        let close = NSButton(title: L10n.string("common.close"), target: self, action: #selector(closePlayer))
        let playControls = NSStackView(views: [playButton, playSpinner])
        playControls.orientation = .horizontal
        playControls.alignment = .centerY
        let controls = NSStackView(views: [previous, skipBackButton, playControls, skipForwardButton, next])
        controls.spacing = 12
        controls.alignment = .centerY
        configureSecondaryControls()
        let options = NSStackView(views: [ratePopUp, contentsButton, sleepPopUp])
        options.spacing = 12
        options.alignment = .centerY
        let content = NSStackView(views: [coverView, titleLabel, statusLabel, timeControls, controls, options, goToReadingButton, close])
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
        cancellable = player.transportContentUpdates.sink { [weak self] _ in self?.refresh() }
        pairingCancellable = player.readerPairing.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        clockCancellable = player.transportUpdates.sink { [weak self] state in self?.refreshClock(state) }
        refresh()
    }

    private func refresh() {
        let transport = player.transportState
        let state = transport.content
        let bookID = player.location.playingBookID
            ?? player.location.readingBookID
        let book = bookID.flatMap { id in library.books.first(where: { $0.id == id }) }
        titleLabel.stringValue = state.job?.bookTitle ?? book?.resolvedTitle ?? L10n.string("player.nothingPlaying")
        coverView.image = book?.coverPNG.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        statusLabel.stringValue = state.isConverting
            ? L10n.string("player.preparingAudio")
            : (state.job == nil ? L10n.string("player.nothingPlaying") : state.chapterTitle)
        if let voice = state.job?.activeVoiceDisplayName { statusLabel.stringValue += "\n" + voice }
        playButton.image = NSImage(systemSymbolName: state.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playButton.setAccessibilityLabel(L10n.string(state.isPlaying ? "player.pause" : "player.play"))
        playButton.toolTip = L10n.string(state.isPlaying ? "player.pause" : "player.play")
        playButton.isHidden = state.isLoading
        // A stopped spinner is invisible but still takes room between the transport buttons.
        playSpinner.isHidden = !state.isLoading
        if state.isLoading { playSpinner.startAnimation(nil) } else { playSpinner.stopAnimation(nil) }
        playButton.isEnabled = state.job != nil || bookID != nil
        refreshSecondaryControls(state, bookID: book?.id)
        refreshClock(transport)
    }

    private func configureSecondaryControls() {
        for (button, identifier, action) in [
            (skipBackButton, "fullPlayer.skipBack", #selector(skipBack)),
            (skipForwardButton, "fullPlayer.skipForward", #selector(skipForward)),
        ] {
            button.imagePosition = .imageOnly
            button.bezelStyle = .texturedRounded
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        for (button, identifier, key, symbol, action) in [
            (contentsButton, "fullPlayer.tableOfContents", "player.toc", "list.bullet", #selector(showContents)),
            (goToReadingButton, "fullPlayer.goToReading", "player.goToReading", "book", #selector(goToReading)),
        ] {
            button.title = L10n.string(key)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .texturedRounded
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
            button.setAccessibilityLabel(L10n.string(key))
        }
        ratePopUp.setAccessibilityIdentifier("fullPlayer.playbackRateButton")
        ratePopUp.setAccessibilityLabel(L10n.string("player.speed"))
        ratePopUp.toolTip = L10n.string("player.speed")

        sleepPopUp.setAccessibilityIdentifier("fullPlayer.sleepTimer")
        sleepPopUp.setAccessibilityLabel(L10n.string("player.sleepTimer"))
        // A pull-down shows its first item as the button title.
        sleepPopUp.addItem(withTitle: L10n.string("player.sleepTimer"))
        for minutes in Self.sleepMinutes {
            let key = minutes == 0 ? "off" : String(minutes)
            let item = NSMenuItem(title: L10n.string("player.sleepTimerOption.\(key)"),
                                  action: #selector(selectSleepTimer(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            sleepPopUp.menu?.addItem(item)
        }
    }

    private func refreshSecondaryControls(_ state: PlaybackTransportState.Content, bookID: String?) {
        let backward = Int(PlaybackSystemSession.configuredSkipInterval(forKey: AppSettings.playbackBackwardSecondsKey))
        let forward = Int(PlaybackSystemSession.configuredSkipInterval(forKey: AppSettings.playbackForwardSecondsKey))
        for (button, symbol, key, seconds) in [
            (skipBackButton, "gobackward", "player.skipBack.seconds", backward),
            (skipForwardButton, "goforward", "player.skipForward.seconds", forward),
        ] {
            button.image = NSImage(systemSymbolName: "\(symbol).\(seconds)", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.setAccessibilityLabel(L10n.string(key, seconds))
            button.toolTip = L10n.string(key, seconds)
            button.isEnabled = state.job != nil
        }
        let rates = PlaybackRate.menuRates(selected: player.rate)
        if ratePopUp.itemTitles != rates.map(\.shortLabel) {
            ratePopUp.removeAllItems()
            for rate in rates {
                let item = NSMenuItem(title: rate.shortLabel, action: #selector(selectRate(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = rate.rawValue
                ratePopUp.menu?.addItem(item)
            }
        }
        ratePopUp.selectItem(withTitle: player.rate.shortLabel)
        contentsButton.isEnabled = state.job?.playableChapters.isEmpty == false
        // Offered whenever no reader is showing the narrated passage and there is a book to open there.
        goToReadingButton.isHidden = player.readerPairing.isPaired || bookID == nil
    }

    private func refreshClock(_ state: PlaybackTransportState) {
        let duration = max(state.clock.durationSeconds, 1)
        progressSlider.maxValue = duration
        progressSlider.doubleValue = min(state.playbackPositionSeconds, duration)
        progressSlider.isEnabled = state.clock.durationSeconds > 0
        elapsedLabel.stringValue = Self.formatTime(state.playbackPositionSeconds)
        remainingLabel.stringValue = "−" + Self.formatTime(max(0, state.clock.durationSeconds - state.playbackPositionSeconds))
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
    @objc private func skipBack() { player.skipBackward(); refresh() }
    @objc private func skipForward() { player.skipForward(); refresh() }

    @objc private func selectRate(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? Float, let rate = PlaybackRate(rawValue: raw) { player.setRate(rate) }
        refresh()
    }

    @objc private func selectSleepTimer(_ sender: NSMenuItem) {
        if sender.tag == 0 { player.setSleepTimer(seconds: 0) } else { player.startSleepTimer(minutes: sender.tag) }
        refresh()
    }

    @objc private func showContents() {
        guard let snapshot = player.snapshot else { return }
        let menu = NSMenu()
        for (position, chapter) in snapshot.playableChapters.enumerated() {
            let item = NSMenuItem(title: chapter.displayTitle, action: #selector(selectChapter(_:)), keyEquivalent: "")
            item.target = self
            item.tag = position
            item.representedObject = snapshot.jobId
            item.state = position == player.currentChapterIndex ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: contentsButton.bounds.maxY), in: contentsButton)
    }

    @objc private func selectChapter(_ sender: NSMenuItem) {
        guard let snapshot = player.snapshot, snapshot.jobId == sender.representedObject as? String,
              snapshot.playableChapters.indices.contains(sender.tag) else { return }
        player.play(snapshot: snapshot, startingAt: sender.tag)
        refresh()
    }

    @objc private func goToReading() {
        guard let bookID = player.location.playingBookID ?? player.location.readingBookID else { return }
        presentation.dismissFullPlayer()
        onGoToReading(bookID)
    }
}

#endif
