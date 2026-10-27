#if os(macOS)
import AppKit
import Combine

@MainActor
final class MacAppKitRootController: NSSplitViewController, NSToolbarDelegate {
    static let sidebarToolbarItemIdentifier = NSToolbarItem.Identifier("app.toggleSidebar")
    private typealias Destination = MacSidebarPresentation.Destination

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
    private lazy var sidebarPresentation = MacSidebarPresentation(
        actionTarget: self, action: #selector(sidebarButtonActivated(_:))
    )
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private lazy var playbackSession = MacReaderPlaybackSession(
        settings: settings, library: library, player: player,
        playerPresentation: playerPresentation, conversionExecutor: conversionExecutor)
    static func shouldShowPlayerBar(
        hasSnapshot: Bool,
        hasCurrentBook: Bool,
        hasPreviouslyOpenedBook: Bool
    ) -> Bool {
        hasSnapshot || hasCurrentBook || hasPreviouslyOpenedBook
    }

    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        bookmarkStore: BookmarkStore,
        playerPresentation: PlayerPresentation? = nil,
        conversionExecutor: @escaping RustConversionCoordinator.StreamingExecutor = RustConversionCoordinator.executeStreaming
    ) {
        self.conversionExecutor = conversionExecutor
        self.settings = settings
        self.library = library
        self.player = player
        self.bookmarkStore = bookmarkStore
        self.playerPresentation = playerPresentation ?? PlayerPresentation()
        self.playerPresentation.dismissFullPlayer()
        super.init(nibName: nil, bundle: nil)
        self.playerBar = MacPlayerBarViewController(player: player, library: library, onStartPlayback: { [weak self] in
            self?.playFromCurrentReaderPosition()
        }, onShowFullPlayer: { [weak playerPresentation] in
            playerPresentation?.showFullPlayer()
        })
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarPresentation.controller)
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 280
        splitViewItems = [
            sidebar,
            NSSplitViewItem(viewController: detailContainer),
        ]
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
            // Read the committed presentation value before opening/closing a sheet.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFullPlayer() }
            .store(in: &cancellables)
        player.$snapshot
            .sink { [weak self] snapshot in
                guard let self, let snapshot, let jobID = self.playbackSession.localPlaybackGeneration,
                      snapshot.jobId != jobID else { return }
                self.playbackSession.cancel(stopPlayer: false)
            }
            .store(in: &cancellables)
        player.$activeStreamingChapterIndex
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] chapterIndex in
                guard let self, self.playbackSession.localPlaybackGeneration != nil,
                      let control = self.playbackSession.localPlaybackControl else { return }
                control.updatePlaybackWindow(currentChapter: chapterIndex, chaptersAhead: 1)
                _ = control.prioritize(chapterIndex: chapterIndex)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: RustConversionOutputStore.willRemoveAudio)
            .sink { [weak self] notification in
                let bookID = notification.userInfo?["bookID"] as? String
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let playingBook = self.playbackSession.localPlaybackBookID
                        ?? UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
                    guard bookID == nil || playingBook == bookID else { return }
                    self.playbackSession.cancel()
                    self.player.stop()
                    self.player.clearConversionState()
                }
            }
            .store(in: &cancellables)
        playbackSession.restorePlaybackIfPossible(owner: self) { [weak self] in self?.refreshPlayerBar() }
        LocalFulltextCache.startPrewarmingRecentBooks()
        show(.library)
        refreshPlayerBar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        ensureApplicationFocus()
    }

    /// Rebuild the paused local queue after launch without reopening the
    /// source EPUB or auto-starting audio.
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
        let toolbar = NSToolbar(identifier: "app.window.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToolbarItemIdentifier]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToolbarItemIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.sidebarToolbarItemIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = L10n.string("nav.toggleSidebar")
        item.toolTip = L10n.string("nav.toggleSidebar")
        item.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: L10n.string("nav.toggleSidebar")
        )
        item.target = self
        item.action = #selector(toggleNavigationSidebar)
        return item
    }

    @objc func toggleNavigationSidebar(_ sender: Any?) {
        // `NSSplitViewController.toggleSidebar(_:)` can target the trailing
        // split item when the window's responder chain changes. The app has
        // one navigation sidebar: make that contract explicit and stable.
        guard let sidebar = splitViewItems.first else { return }
        sidebar.isCollapsed.toggle()
        view.window?.invalidateRestorableState()
    }

    @objc func importBooks(_ sender: Any?) {
        show(.library)
        (controllers[.library] as? MacLibraryViewController)?.importBooks()
    }

    @objc func showSettings(_ sender: Any?) { show(.settings) }

    @objc func focusLibrarySearch(_ sender: Any?) {
        show(.library)
        (controllers[.library] as? MacLibraryViewController)?.focusSearch()
    }

    @objc private func sidebarButtonActivated(_ sender: NSButton) {
        guard let destination = Destination(rawValue: sender.tag) else { return }
        show(destination)
    }

    private func show(_ destination: Destination) {
        sidebarPresentation.select(destination)
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
                onOpenBook: { [weak self] bookID in self?.showReader(bookID: bookID) },
                    onDownloadBook: { [weak self] bookID in
                        self?.showBookDetail(bookID: bookID)
                        (self?.detailController as? MacBookDetailViewController)?.downloadWholeBook()
                    },
                    onConvertBook: { [weak self] bookID in
                        self?.showBookDetail(bookID: bookID)
                        (self?.detailController as? MacBookDetailViewController)?.convertWholeBook()
                    }
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
        detailContainer.view.setAccessibilityChildren([contentView, playerBar.view])
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = controller
    }

    private func showBookDetail(bookID: String) {
        guard let book = library.books.first(where: { $0.id == bookID }) else { return }
        playbackSession.cancel(ifReplacingBook: bookID)
        sidebarPresentation.select(.library)
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
        detailContainer.view.setAccessibilityChildren([contentView, playerBar.view])
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = detail
    }

    func showReader(bookID: String) {
        playbackSession.cancel(ifReplacingBook: bookID)
        sidebarPresentation.select(.library)
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
        detailContainer.view.setAccessibilityChildren([contentView, playerBar.view])
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = reader
        refreshPlayerBar()
    }

    func startPlaybackForCurrentBook() {
        playbackSession.start(owner: self)
    }

    /// A macOS Play tap follows the reader's visible location. The reader
    /// publishes an EPUB-indexed chapter and page ratio for both scrolling
    /// and TOC navigation, so a selected TOC chapter never resumes stale
    /// audio from a previous chapter.
    private func playFromCurrentReaderPosition() {
        // Preserve normal Pause; paused Play resolves reader movement explicitly.
        guard let bookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) else {
            if player.snapshot == nil { startPlaybackForCurrentBook() } else { player.resume() }
            return
        }
        let chapterIndex = ReaderPlaybackPriorityChapter.index(bookID: bookID)
        let pageRatio = readerPageRatio(bookID: bookID)
        let belongsToReader = player.isPlaybackForReaderBook(bookID)
            || (player.snapshot != nil && library.books.first(where: { $0.id == bookID })?.lastJobId == player.snapshot?.jobId)
        if player.hasLoadedAudioQueue, belongsToReader {
            let decision = player.playTapDecision(readerChapterIndex: chapterIndex, readerPageRatio: pageRatio)
            let playable = player.snapshot?.playableChapters ?? []
            let audibleChapter = player.activeStreamingChapterIndex
                ?? (playable.indices.contains(player.currentChapterIndex)
                    ? playable[player.currentChapterIndex].index : nil)
            if case .offerStartChoice = decision, let audibleChapter, audibleChapter != chapterIndex {
                // A newly selected chapter requires a new source-bound Rust job.
                playbackSession.start(owner: self)
                return
            }
            switch decision {
            case .pause: player.pause()
            case .resume: player.resume()
            case .startFromReaderPage: playCurrentReaderPage()
            case .offerStartChoice:
                let alert = NSAlert()
                alert.messageText = L10n.string("player.divergence.title")
                alert.informativeText = L10n.string("player.divergence.message")
                alert.addButton(withTitle: L10n.string("player.divergence.fromWhereStopped"))
                alert.addButton(withTitle: L10n.string("player.divergence.fromCurrentPage"))
                alert.addButton(withTitle: L10n.string("common.cancel"))
                let resolve: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                    guard let self else { return }
                    if response == .alertSecondButtonReturn { self.playCurrentReaderPage() }
                    else if response == .alertFirstButtonReturn {
                        self.player.rememberReaderPlaybackAnchor()
                        self.player.resume()
                    }
                }
                if let window = view.window { alert.beginSheetModal(for: window, completionHandler: resolve) }
            }
            return
        }
        if !belongsToReader, player.snapshot != nil {
            startPlaybackForCurrentBook()
        } else if let snapshot = player.snapshot,
           snapshot.state == "finished" || snapshot.playableChapters.contains(where: { $0.index == chapterIndex }) {
            playCurrentReaderPage()
        } else {
            startPlaybackForCurrentBook()
        }
    }

    private func readerPageRatio(bookID: String) -> Double? {
        UserDefaults.standard.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double
            ?? ReaderProgressStore.read(bookId: bookID)?.offsetFraction
    }

    private func playCurrentReaderPage() {
        guard let bookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) else { return }
        guard player.isPlaybackForReaderBook(bookID)
            || (player.snapshot != nil && library.books.first(where: { $0.id == bookID })?.lastJobId == player.snapshot?.jobId) else { return }
        if playbackSession.localPlaybackGeneration != nil
            || player.snapshot?.chapterProgress?.contains(where: { ($0.textOffset ?? 0) > 0 }) == true {
            // Partial audio needs a new Rust source range and job identity.
            playbackSession.start(owner: self)
        } else {
            player.startFromReaderPage(ReaderPlaybackPriorityChapter.index(bookID: bookID),
                sentenceId: UserDefaults.standard.string(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey),
                sentenceOffsetRatio: readerPageRatio(bookID: bookID))
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
                onStartPlayback: { [weak self] in self?.playFromCurrentReaderPosition() }
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
        syncPlayerCoverArt()
        let hasReadingContext = player.snapshot != nil
            || UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) != nil
            || library.books.contains { $0.lastOpenedAt != nil }
        // Keep the internal stack constrained to the full bar width. Toggling
        // only `isHidden` leaves the bar visible with its edge constraints
        // deactivated, which collapses the content to the leading edge and
        // creates a large empty region beside the mini-player controls.
        playerBar.setCollapsed(!hasReadingContext)
        playerBarHeightConstraint?.constant = hasReadingContext ? 60 : 0
    }

    private func syncPlayerCoverArt() {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let cover = bookID.flatMap { id in library.books.first(where: { $0.id == id })?.coverPNG }
        player.updateCoverArtData(cover)
    }
}

private extension NSViewController {
    func removeChildControllers() {
        children.forEach { $0.removeFromParent() }
    }
}
#endif
