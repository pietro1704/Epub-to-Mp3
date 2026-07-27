#if os(macOS)
import AppKit
import Combine

@MainActor
final class MacAppKitRootController: NSSplitViewController {
    private enum Destination: Int, CaseIterable {
        case library, jobs, settings
        var title: String {
            switch self {
            case .library: return L10n.string("nav.library")
            case .jobs: return L10n.string("nav.conversions")
            case .settings: return L10n.string("nav.settings")
            }
        }
        var icon: String {
            switch self {
            case .library: return "books.vertical"
            case .jobs: return "arrow.triangle.2.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    private let settings: AppSettings
    private let library: LibraryStore
    private let bookmarkStore: BookmarkStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let detailContainer = NSViewController()
    private var playerBar: MacPlayerBarViewController!
    private var playerBarHeightConstraint: NSLayoutConstraint?
    private var cancellables: Set<AnyCancellable> = []
    private var detailController: NSViewController?
    private var fullPlayerController: MacFullPlayerViewController?
    private var controllers: [Destination: NSViewController] = [:]
    private var sidebarButtons: [Destination: NSButton] = [:]

    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        bookmarkStore: BookmarkStore,
        playerPresentation: PlayerPresentation = PlayerPresentation()
    ) {
        self.settings = settings
        self.library = library
        self.player = player
        self.bookmarkStore = bookmarkStore
        self.playerPresentation = playerPresentation
        self.playerPresentation.dismissFullPlayer()
        super.init(nibName: nil, bundle: nil)
        self.playerBar = MacPlayerBarViewController(player: player, library: library, onStartPlayback: { [weak self] in
            self?.startPlaybackForCurrentBook()
        }, onShowFullPlayer: { [weak playerPresentation] in
            playerPresentation?.showFullPlayer()
        })
        splitViewItems = [
            NSSplitViewItem(viewController: makeSidebar()),
            NSSplitViewItem(viewController: detailContainer),
        ]
        splitViewItems[0].minimumThickness = 190
        splitViewItems[0].maximumThickness = 280
        splitViewItems[0].canCollapse = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        detailContainer.view.addSubview(playerBar.view)
        playerBar.view.translatesAutoresizingMaskIntoConstraints = false
        let playerBarHeight = playerBar.view.heightAnchor.constraint(equalToConstant: 0)
        playerBarHeightConstraint = playerBarHeight
        NSLayoutConstraint.activate([
            playerBar.view.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            playerBar.view.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            playerBar.view.bottomAnchor.constraint(equalTo: detailContainer.view.bottomAnchor),
            playerBarHeight,
        ])
        player.objectWillChange
            .sink { [weak self] _ in self?.refreshPlayerBar() }
            .store(in: &cancellables)
        playerPresentation.objectWillChange
            .sink { [weak self] _ in self?.refreshFullPlayer() }
            .store(in: &cancellables)
        show(.library)
        refreshPlayerBar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let contentView = view.window?.contentView else { return }
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        ensureApplicationFocus()
    }

    /// AppKit can leave the window visible but inactive after a build,
    /// notification, or another app's modal surface takes focus. Restore
    /// focus whenever this root controller needs to be interactive.
    func ensureApplicationFocus() {
        guard let window = view.window else { return }
        if !window.isKeyWindow || !NSApp.isActive {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func configureWindowToolbar(_ window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        let button = NSButton(
            image: NSImage(
                systemSymbolName: "sidebar.left",
                accessibilityDescription: L10n.string("nav.toggleSidebar")
            ) ?? NSImage(),
            target: self,
            action: #selector(toggleNavigationSidebar)
        )
        button.bezelStyle = .texturedRounded
        button.toolTip = L10n.string("nav.toggleSidebar")
        button.setAccessibilityLabel(L10n.string("nav.toggleSidebar"))
        button.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 28),
            container.heightAnchor.constraint(equalToConstant: 28),
        ])
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func toggleNavigationSidebar() {
        let sidebarItem = splitViewItems[0]
        sidebarItem.isCollapsed.toggle()
    }

    private func makeSidebar() -> NSViewController {
        let controller = NSViewController()
        let toggle = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L10n.string("nav.toggleSidebar")) ?? NSImage(), target: self, action: #selector(toggleNavigationSidebar))
        toggle.bezelStyle = .texturedRounded
        toggle.toolTip = L10n.string("nav.toggleSidebar")
        toggle.setAccessibilityLabel(L10n.string("nav.toggleSidebar"))
        let title = NSTextField(labelWithString: "Epub-to-Mp3")
        title.font = .boldSystemFont(ofSize: 16)
        let menu = NSStackView()
        menu.orientation = .vertical
        menu.alignment = .width
        menu.spacing = 4
        for destination in Destination.allCases {
            let button = NSButton(title: destination.title, target: self, action: #selector(sidebarButtonActivated(_:)))
            button.tag = destination.rawValue
            button.alignment = .left
            button.image = NSImage(systemSymbolName: destination.icon, accessibilityDescription: destination.title)
            button.imagePosition = .imageLeading
            button.isBordered = false
            button.focusRingType = .none
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityLabel(destination.title)
            sidebarButtons[destination] = button
            menu.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = NSStackView(views: [toggle, title, menu, spacer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view = stack
        return controller
    }

    @objc private func sidebarButtonActivated(_ sender: NSButton) {
        guard let destination = Destination(rawValue: sender.tag) else { return }
        show(destination)
    }

    private func show(_ destination: Destination) {
        updateSidebarSelection(destination)
        if let detailController, detailController === controllers[destination] {
            return
        }
        let controller: NSViewController
        if let existing = controllers[destination] {
            controller = existing
        } else {
            switch destination {
            case .library:
                controller = MacLibraryViewController(
                    library: library,
                    bookmarkStore: bookmarkStore,
                onOpenBook: { [weak self] bookID in self?.showReader(bookID: bookID) }
                )
            case .jobs: controller = MacJobsListViewController()
            case .settings: controller = MacSettingsViewController(settings: settings, library: library)
            }
            controllers[destination] = controller
        }
        if let current = detailController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        detailContainer.addChild(controller)
        let contentView = controller.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(contentView)
        detailContainer.view.setAccessibilityChildren([contentView])
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = controller
    }

    private func updateSidebarSelection(_ destination: Destination) {
        for (candidate, button) in sidebarButtons {
            let selected = candidate == destination
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            button.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
                : NSColor.clear.cgColor
        }
    }

    private func showBookDetail(bookID: String) {
        guard let book = library.books.first(where: { $0.id == bookID }) else { return }
        updateSidebarSelection(.library)
        let detail = MacBookDetailViewController(
            book: book,
            library: library,
            settings: settings,
            player: player,
            playerPresentation: playerPresentation,
            onRead: { [weak self] bookID in self?.showReader(bookID: bookID) },
            onShowJobs: { [weak self] in self?.show(.jobs) }
        )
        if let current = detailController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        detailContainer.addChild(detail)
        let contentView = detail.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(contentView)
        detailContainer.view.setAccessibilityChildren([contentView])
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = detail
    }

    private func showReader(bookID: String) {
        updateSidebarSelection(.library)
        let reader = MacReaderViewController(
            library: library,
            settings: settings,
            player: player,
            bookmarkStore: bookmarkStore,
            onClose: { [weak self] in self?.show(.library) }
        )
        reader.setBook(bookID)
        if let current = detailController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        detailContainer.addChild(reader)
        let contentView = reader.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(contentView)
        detailContainer.view.setAccessibilityChildren([contentView])
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = reader
        refreshPlayerBar()
    }

    private func startPlaybackForCurrentBook() {
        playerPresentation.dismissFullPlayer()
        guard let bookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              let book = library.books.first(where: { $0.id == bookID }),
              let url = try? library.openBookFile(id: bookID) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await EmbeddedConversionCoordinator.stream(
                    bookURL: url,
                    bookID: book.id,
                    player: player
                )
                library.recordConversion(jobId: snapshot.jobId, for: book.id)
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    private func refreshFullPlayer() {
        guard isViewLoaded else { return }
        if playerPresentation.showingFullPlayer {
            guard presentedViewControllers?.isEmpty != false else { return }
            let controller = MacFullPlayerViewController(
                player: player,
                library: library,
                presentation: playerPresentation,
                onStartPlayback: { [weak self] in self?.startPlaybackForCurrentBook() }
            )
            controller.preferredContentSize = view.window?.contentView?.bounds.size ?? NSSize(width: 1000, height: 700)
            fullPlayerController = controller
            presentAsSheet(controller)
        } else if let controller = fullPlayerController {
            controller.dismiss(nil)
            fullPlayerController = nil
        }
    }

    private func refreshPlayerBar() {
        let hasReadingContext = player.snapshot != nil
            || UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) != nil
            || library.books.contains { $0.lastOpenedAt != nil }
        playerBar.view.isHidden = !hasReadingContext
        playerBarHeightConstraint?.constant = hasReadingContext ? 76 : 0
    }
}

@MainActor
private final class MacPlayerBarViewController: NSViewController {
    private let player: AudioPlayer
    private let library: LibraryStore
    private let onStartPlayback: () -> Void
    private let onShowFullPlayer: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let chapterLabel = NSTextField(labelWithString: "")
    private let etaLabel = NSTextField(labelWithString: "")
    private let coverView = NSImageView()
    private let progress = NSProgressIndicator()
    private let playButton = NSButton()
    private let nextButton = NSButton()
    private let rateButton = NSButton()
    private var cancellable: AnyCancellable?

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
        progress.isIndeterminate = false
        progress.style = .bar
        progress.controlSize = .small
        progress.maxValue = 1
        playButton.imagePosition = .imageOnly
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        nextButton.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: L10n.string("player.nextChapter"))
        nextButton.bezelStyle = .texturedRounded
        nextButton.target = self
        nextButton.action = #selector(nextChapter)
        rateButton.bezelStyle = .texturedRounded
        rateButton.target = self
        rateButton.action = #selector(showRateMenu)
        let labels = NSStackView(views: [titleLabel, chapterLabel, etaLabel])
        labels.orientation = .vertical
        labels.spacing = 2
        let info = NSStackView(views: [coverView, labels])
        info.orientation = .horizontal
        info.spacing = 10
        let openButton = NSButton()
        openButton.isBordered = false
        openButton.target = self
        openButton.action = #selector(showFullPlayer)
        openButton.addSubview(info)
        info.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: openButton.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: openButton.trailingAnchor),
            info.topAnchor.constraint(equalTo: openButton.topAnchor),
            info.bottomAnchor.constraint(equalTo: openButton.bottomAnchor),
        ])
        let stack = NSStackView(views: [openButton, playButton, nextButton, rateButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        background.addSubview(stack)
        background.addSubview(progress)
        stack.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -5),
            info.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            coverView.widthAnchor.constraint(equalToConstant: 44),
            coverView.heightAnchor.constraint(equalToConstant: 44),
            progress.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            progress.topAnchor.constraint(equalTo: background.topAnchor),
            progress.heightAnchor.constraint(equalToConstant: 3),
        ])
        openButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        openButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [playButton, nextButton, rateButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        view = background
        cancellable = player.objectWillChange.sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    @objc private func togglePlayback() {
        if player.snapshot == nil { onStartPlayback() } else { player.togglePlayPause() }
        refresh()
    }
    @objc private func nextChapter() { player.nextChapter(); refresh() }
    @objc private func showRateMenu() {
        let menu = NSMenu()
        PlaybackRate.allCases.forEach { rate in
            let item = NSMenuItem(title: rate.shortLabel, action: #selector(selectRate(_:)), keyEquivalent: "")
            item.representedObject = rate.rawValue
            item.state = rate == player.rate ? .on : .off
            menu.addItem(item)
        }
        rateButton.menu = menu
        rateButton.performClick(nil)
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
        titleLabel.stringValue = book?.resolvedTitle ?? player.snapshot?.bookTitle ?? L10n.string("player.nothingPlaying")
        chapterLabel.stringValue = player.snapshot == nil ? "" : player.effectiveChapterTitle
        etaLabel.stringValue = player.durationSeconds > 0
            ? L10n.string("player.remaining", formatTime(player.playbackDurationSeconds - player.playbackPositionSeconds))
            : ""
        coverView.image = book?.coverPNG.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        let fraction = player.durationSeconds > 0 ? player.positionSeconds / player.durationSeconds : 0
        progress.doubleValue = min(1, max(0, fraction))
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        rateButton.title = player.rate.shortLabel
        playButton.isEnabled = player.snapshot != nil || currentBookID != nil
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

@MainActor
private final class MacFullPlayerViewController: NSViewController {
    private let player: AudioPlayer
    private let library: LibraryStore
    private let presentation: PlayerPresentation
    private let onStartPlayback: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let coverView = NSImageView()
    private let playButton = NSButton()
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
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        playButton.imagePosition = .imageOnly
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        let previous = NSButton(image: NSImage(systemSymbolName: "backward.end.fill", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(previousChapter))
        let next = NSButton(image: NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil) ?? NSImage(), target: self, action: #selector(nextChapter))
        let close = NSButton(title: L10n.string("common.close"), target: self, action: #selector(closePlayer))
        let controls = NSStackView(views: [previous, playButton, next])
        controls.spacing = 12
        controls.alignment = .centerY
        let content = NSStackView(views: [coverView, titleLabel, statusLabel, controls, close])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 22
        content.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 280),
            coverView.heightAnchor.constraint(equalToConstant: 280),
        ])
        view = background
        cancellable = player.objectWillChange.sink { [weak self] _ in self?.refresh() }
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
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playButton.isEnabled = player.snapshot != nil || bookID != nil
    }

    @objc private func togglePlayback() {
        if player.snapshot == nil { onStartPlayback() } else { player.togglePlayPause() }
        refresh()
    }
    @objc private func previousChapter() { player.previousChapter() }
    @objc private func nextChapter() { player.nextChapter() }
    @objc private func closePlayer() { presentation.dismissFullPlayer() }
}

private extension NSViewController {
    func removeChildControllers() {
        children.forEach { $0.removeFromParent() }
    }
}
#endif
