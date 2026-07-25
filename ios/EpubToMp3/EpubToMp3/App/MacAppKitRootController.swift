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
    private let playerBar: MacPlayerBarViewController
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
        self.playerBar = MacPlayerBarViewController(player: player, onShowFullPlayer: { [weak playerPresentation] in
            playerPresentation?.showFullPlayer()
        })
        super.init(nibName: nil, bundle: nil)
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
                    onOpenBook: { [weak self] bookID in self?.showBookDetail(bookID: bookID) }
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

    private func refreshFullPlayer() {
        guard isViewLoaded else { return }
        if playerPresentation.showingFullPlayer {
            guard presentedViewControllers?.isEmpty != false else { return }
            let controller = MacFullPlayerViewController(player: player, presentation: playerPresentation)
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
        playerBarHeightConstraint?.constant = hasReadingContext ? 58 : 0
    }
}

@MainActor
private final class MacPlayerBarViewController: NSViewController {
    private let player: AudioPlayer
    private let onShowFullPlayer: () -> Void
    private let titleLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private var cancellable: AnyCancellable?

    init(player: AudioPlayer, onShowFullPlayer: @escaping () -> Void) {
        self.player = player
        self.onShowFullPlayer = onShowFullPlayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        let skip = NSButton(title: "30s", target: self, action: #selector(skipForward))
        let full = NSButton(title: L10n.string("player.fullPlayer"), target: self, action: #selector(showFullPlayer))
        playButton.title = L10n.string("player.play")
        playButton.bezelStyle = .texturedRounded
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        titleLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [titleLabel, skip, playButton, full])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
        background.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        view = background
        cancellable = player.objectWillChange.sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    @objc private func togglePlayback() { player.togglePlayPause(); refresh() }
    @objc private func skipForward() { player.skipForward(seconds: 30) }
    @objc private func showFullPlayer() { onShowFullPlayer() }

    private func refresh() {
        titleLabel.stringValue = player.snapshot?.bookTitle ?? L10n.string("player.nothingPlaying")
        playButton.title = player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play")
        playButton.isEnabled = player.snapshot != nil
    }
}

@MainActor
private final class MacFullPlayerViewController: NSViewController {
    private let player: AudioPlayer
    private let presentation: PlayerPresentation
    private let titleLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()

    init(player: AudioPlayer, presentation: PlayerPresentation) {
        self.player = player
        self.presentation = presentation
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center
        titleLabel.stringValue = player.snapshot?.bookTitle ?? L10n.string("player.nothingPlaying")
        playButton.title = player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play")
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        let previous = NSButton(title: "|<", target: self, action: #selector(previousChapter))
        let next = NSButton(title: ">|", target: self, action: #selector(nextChapter))
        let close = NSButton(title: L10n.string("common.close"), target: self, action: #selector(closePlayer))
        let controls = NSStackView(views: [previous, playButton, next])
        controls.spacing = 12
        controls.alignment = .centerY
        let stack = NSStackView(views: [titleLabel, controls, close])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        view = stack
    }

    @objc private func togglePlayback() { player.togglePlayPause(); playButton.title = player.isPlaying ? L10n.string("player.pause") : L10n.string("player.play") }
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
