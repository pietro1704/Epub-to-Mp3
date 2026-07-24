#if os(macOS)
import AppKit
import Combine

@MainActor
final class MacAppKitRootController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Destination: Int, CaseIterable {
        case reader, library, jobs, settings
        var title: String {
            switch self {
            case .reader: return L10n.string("nav.read")
            case .library: return L10n.string("nav.library")
            case .jobs: return L10n.string("nav.conversions")
            case .settings: return L10n.string("nav.settings")
            }
        }
        var icon: String {
            switch self {
            case .reader: return "book"
            case .library: return "books.vertical"
            case .jobs: return "arrow.triangle.2.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let sidebar = NSTableView()
    private let detail = NSViewController()
    private let playerBar: MacPlayerBarViewController
    private var cancellables: Set<AnyCancellable> = []
    private var fullPlayerController: MacFullPlayerViewController?

    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation = PlayerPresentation()
    ) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playerPresentation = playerPresentation
        self.playerBar = MacPlayerBarViewController(player: player, onShowFullPlayer: { [weak playerPresentation] in
            playerPresentation?.showFullPlayer()
        })
        super.init(nibName: nil, bundle: nil)
        splitViewItems = [NSSplitViewItem(viewController: makeSidebar()), NSSplitViewItem(viewController: detail)]
        splitViewItems[0].minimumThickness = 190
        splitViewItems[0].maximumThickness = 280
        library.$books.sink { [weak self] _ in self?.refreshDetailIfNeeded() }.store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(playerBar)
        view.addSubview(playerBar.view)
        playerBar.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerBar.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerBar.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerBar.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerBar.view.heightAnchor.constraint(equalToConstant: 58)
        ])
        playerBar.didMove(toParent: self)
        playerPresentation.objectWillChange
            .sink { [weak self] _ in self?.refreshFullPlayer() }
            .store(in: &cancellables)
        sidebar.selectRowIndexes(IndexSet(integer: Destination.reader.rawValue), byExtendingSelection: false)
        show(.reader)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Destination.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let item = Destination.allCases[row]
        let image = NSImageView(image: NSImage(systemSymbolName: item.icon, accessibilityDescription: nil) ?? NSImage())
        let label = NSTextField(labelWithString: item.title)
        let stack = NSStackView(views: [image, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView,
              let destination = Destination(rawValue: table.selectedRow) else { return }
        show(destination)
    }

    private func makeSidebar() -> NSViewController {
        let controller = NSViewController()
        sidebar.headerView = nil
        sidebar.delegate = self
        sidebar.dataSource = self
        sidebar.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination")))
        sidebar.rowSizeStyle = .medium
        let title = NSTextField(labelWithString: "Epub-to-Mp3")
        title.font = .boldSystemFont(ofSize: 16)
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [title, scroll])
        stack.orientation = .vertical
        stack.alignment = .stretch
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 12, bottom: 12, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view = stack
        return controller
    }

    private func show(_ destination: Destination) {
        let controller: NSViewController
        switch destination {
        case .reader: controller = MacReaderViewController(library: library, settings: settings, player: player)
        case .library: controller = MacLibraryViewController(library: library, settings: settings)
        case .jobs: controller = MacJobsListViewController(settings: settings)
        case .settings: controller = MacSettingsViewController(settings: settings, library: library)
        }
        detail.removeChildControllers()
        detail.addChild(controller)
        detail.view = controller.view
        controller.didMove(toParent: detail)
    }

    private func refreshDetailIfNeeded() {
        guard sidebar.selectedRow == Destination.reader.rawValue else { return }
        show(.reader)
    }

    private func refreshFullPlayer() {
        guard isViewLoaded else { return }
        if playerPresentation.showingFullPlayer {
            guard presentedViewControllers.isEmpty else { return }
            let controller = MacFullPlayerViewController(player: player, presentation: playerPresentation)
            fullPlayerController = controller
            presentAsSheet(controller)
        } else if let controller = fullPlayerController {
            controller.dismiss(nil)
            fullPlayerController = nil
        }
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
