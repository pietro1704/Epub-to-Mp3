#if os(macOS)
import AppKit
import Combine

@MainActor
final class MacPlayerBarViewController: NSViewController {
    private let player: AudioPlayer
    private let library: LibraryStore
    private let onStartPlayback: () -> Void
    private let onShowFullPlayer: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let chapterLabel = NSTextField(labelWithString: "")
    private let etaLabel = NSTextField(labelWithString: "")
    private let coverView = NSImageView()
    private let playButton = NSButton()
    private let playSpinner = NSProgressIndicator()
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let rateButton = NSButton()
    private var cancellable: AnyCancellable?
    private var contentEdgeConstraints: [NSLayoutConstraint] = []
    private var isCollapsed = true

    init(player: AudioPlayer, library: LibraryStore, onStartPlayback: @escaping () -> Void, onShowFullPlayer: @escaping () -> Void) {
        self.player = player
        self.library = library
        self.onStartPlayback = onStartPlayback
        self.onShowFullPlayer = onShowFullPlayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 5
        coverView.layer?.masksToBounds = true
        coverView.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        chapterLabel.textColor = .secondaryLabelColor
        chapterLabel.font = .systemFont(ofSize: 11)
        etaLabel.textColor = .secondaryLabelColor
        etaLabel.font = .systemFont(ofSize: 10)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        playButton.imagePosition = .imageOnly
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playSpinner.style = .spinning
        playSpinner.isDisplayedWhenStopped = false
        playSpinner.controlSize = .small
        playButton.setAccessibilityLabel(L10n.string("player.play"))
        playButton.toolTip = L10n.string("player.play")
        previousButton.image = NSImage(systemSymbolName: "backward.end.fill", accessibilityDescription: L10n.string("player.previousChapter"))
        previousButton.bezelStyle = .texturedRounded
        previousButton.target = self
        previousButton.action = #selector(previousChapter)
        previousButton.setAccessibilityLabel(L10n.string("player.previousChapter"))
        previousButton.toolTip = L10n.string("player.previousChapter")
        nextButton.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: L10n.string("player.nextChapter"))
        nextButton.bezelStyle = .texturedRounded
        nextButton.target = self
        nextButton.action = #selector(nextChapter)
        nextButton.setAccessibilityLabel(L10n.string("player.nextChapter"))
        nextButton.toolTip = L10n.string("player.nextChapter")
        rateButton.bezelStyle = .texturedRounded
        rateButton.target = self
        rateButton.action = #selector(showRateMenu)
        rateButton.setAccessibilityLabel(L10n.string("player.speed"))
        rateButton.toolTip = L10n.string("player.speed")
        let labels = NSStackView(views: [titleLabel, chapterLabel, etaLabel])
        labels.orientation = .vertical
        labels.spacing = 2
        let info = NSStackView(views: [coverView, labels])
        info.orientation = .horizontal
        info.spacing = 10
        let openButton = NSButton()
        openButton.title = ""
        openButton.isBordered = false
        openButton.target = self
        openButton.action = #selector(showFullPlayer)
        openButton.setAccessibilityLabel(L10n.string("player.openFullPlayer"))
        openButton.toolTip = L10n.string("player.openFullPlayer")
        openButton.addSubview(info)
        info.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: openButton.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: openButton.trailingAnchor),
            info.topAnchor.constraint(equalTo: openButton.topAnchor),
            info.bottomAnchor.constraint(equalTo: openButton.bottomAnchor),
        ])
        let playControls = NSStackView(views: [playButton, playSpinner])
        playControls.orientation = .horizontal
        playControls.alignment = .centerY
        let stack = NSStackView(views: [openButton, previousButton, playControls, nextButton, rateButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentEdgeConstraints = [
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            info.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            coverView.widthAnchor.constraint(equalToConstant: 44),
            coverView.heightAnchor.constraint(equalToConstant: 44),
        ])
        if !isCollapsed {
            NSLayoutConstraint.activate(contentEdgeConstraints)
        }
        openButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [previousButton, playButton, nextButton, rateButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        view = background
        // objectWillChange fires before @Published stores its new value.
        // Read transport state on the next main-loop turn so an external
        // pause/resume updates the displayed action to the committed state.
        cancellable = player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func setCollapsed(_ collapsed: Bool) {
        isCollapsed = collapsed
        view.isHidden = collapsed
        if collapsed {
            NSLayoutConstraint.deactivate(contentEdgeConstraints)
        } else {
            NSLayoutConstraint.activate(contentEdgeConstraints)
        }
    }

    @objc private func togglePlayback() {
        if player.isPlaying {
            player.pause()
            refresh()
            return
        }

        onStartPlayback()
        refresh()
    }
    @objc private func previousChapter() { player.previousChapter(); refresh() }
    @objc private func nextChapter() { player.nextChapter(); refresh() }
    @objc private func showRateMenu() {
        let menu = NSMenu()
        PlaybackRate.primaryRates.forEach { rate in
            let item = NSMenuItem(title: rate.shortLabel, action: #selector(selectRate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rate.rawValue
            item.state = rate == player.rate ? .on : .off
            menu.addItem(item)
        }
        rateButton.menu = menu
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: rateButton.bounds.maxY), in: rateButton)
    }
    @objc private func selectRate(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? Float, let rate = PlaybackRate(rawValue: raw) { player.setRate(rate) }
        refresh()
    }
    @objc private func showFullPlayer() { onShowFullPlayer() }

    private func refresh() {
        let currentBookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let book = currentBookID.flatMap { id in library.books.first(where: { $0.id == id }) }
        let bookTitle = book?.resolvedTitle ?? player.snapshot?.bookTitle ?? L10n.string("player.nothingPlaying")
        titleLabel.stringValue = player.snapshot == nil ? bookTitle : player.effectiveChapterTitle
        chapterLabel.stringValue = player.snapshot == nil ? "" : bookTitle
        etaLabel.stringValue = player.durationSeconds > 0
            ? L10n.string("player.remaining", formatTime(player.playbackDurationSeconds - player.playbackPositionSeconds))
            : ""
        coverView.image = book?.coverPNG.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playButton.setAccessibilityLabel(L10n.string(player.isPlaying ? "player.pause" : "player.play"))
        playButton.toolTip = L10n.string(player.isPlaying ? "player.pause" : "player.play")
        playButton.isHidden = player.isLoading
        if player.isLoading { playSpinner.startAnimation(nil) } else { playSpinner.stopAnimation(nil) }
        rateButton.title = player.rate.shortLabel
        playButton.isEnabled = player.snapshot != nil || currentBookID != nil
        previousButton.isEnabled = player.snapshot != nil
        nextButton.isEnabled = player.snapshot != nil
        rateButton.isEnabled = player.snapshot != nil
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

#endif
