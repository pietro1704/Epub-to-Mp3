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
    private var readerChromeHidden = false
    private var cancellables: Set<AnyCancellable> = []
    private var detailController: NSViewController?
    private var fullPlayerController: MacFullPlayerViewController?
    private var controllers: [Destination: NSViewController] = [:]
    private lazy var sidebarPresentation = MacSidebarPresentation(
        actionTarget: self, action: #selector(sidebarButtonActivated(_:))
    )
    private let voicePicker = MacReaderVoicePickerPresenter()
    private let conversionExecutor: RustConversionCoordinator.StreamingExecutor
    private lazy var playbackSession = MacReaderPlaybackSession(
        settings: settings, library: library, player: player,
        playerPresentation: playerPresentation, conversionExecutor: conversionExecutor)
    private lazy var bookDownload = MacBookDownloadAction(
        library: library,
        currentSnapshot: { [weak self] in self?.player.snapshot },
        streamingOwner: { [weak self] in
            guard let session = self?.playbackSession, let bookID = session.localPlaybackBookID,
                  let jobID = session.localPlaybackGeneration else { return nil }
            return (bookID, jobID)
        },
        presentUnavailable: { [weak self] in MacBookDownloadAction.presentUnavailable(in: self?.view.window) })
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
        self.playerBar.onDismiss = { [weak self] in self?.dismissMiniPlayer() }
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
        player.transportContentUpdates
            .sink { [weak self] _ in self?.refreshPlayerBar() }
            .store(in: &cancellables)
        playerPresentation.objectWillChange
            // Read the committed presentation value before opening/closing a sheet.
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFullPlayer() }
            .store(in: &cancellables)
        playbackSession.observePlayback()
        playbackSession.readerChapterEstimates = { [weak self] bookID in
            guard self?.player.location.readingBookID == bookID else { return [:] }
            return (self?.detailController as? MacReaderViewController)?.pdfChapterEstimates ?? [:]
        }
        // The Settings speed and the player's speed are one preference.
        settings.$playbackRate.removeDuplicates()
            .sink { [weak player] rate in
                if player?.rate != rate { player?.setRate(rate) }
            }
            .store(in: &cancellables)
        player.$rate.dropFirst().removeDuplicates()
            .sink { [weak settings] rate in
                if settings?.playbackRate != rate { settings?.playbackRate = rate }
            }
            .store(in: &cancellables)
        player.restartReaderListening = { [weak self] chapter, ratio in
            guard let self, let bookID = self.player.location.readingBookID,
                  let book = self.library.books.first(where: { $0.id == bookID }),
                  self.player.isPlaybackForReaderBook(bookID) || self.player.snapshot?.jobId == book.lastJobId,
                  self.playbackSession.localPlaybackBookID == bookID
                    || self.player.snapshot?.chapterProgress?.contains(where: { ($0.textOffset ?? 0) > 0 }) == true
            else { return false }
            self.playbackSession.start(owner: self, chapterOverride: chapter, pageRatioOverride: .some(ratio))
            return true
        }
        PlaybackRelaunchRestoration.restore(
            settings: settings, library: library,
            player: player, owner: self,
            isListeningActive: { [weak playbackSession] in playbackSession?.localPlaybackGeneration != nil }
        ) { [weak self] in self?.refreshPlayerBar() }
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

    /// Items before the tracking separator are drawn over the sidebar and follow
    /// its divider; with the sidebar collapsed the toggle stays at the leading edge.
    static let toolbarItemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarToolbarItemIdentifier, .sidebarTrackingSeparator,
    ]

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarItemIdentifiers
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
                    library: library, location: player.location,
                    bookmarkStore: bookmarkStore,
                onOpenBook: { [weak self] bookID in self?.showReader(bookID: bookID) },
                    onDownloadBook: { [weak self] bookID in
                        Task { [weak self] in await self?.bookDownload.download(bookID: bookID) }
                    },
                    onConvertBook: { [weak self] bookID in
                        self?.showConverter(bookID: bookID)
                    }
                )
            case .convert:
                let converter = MacConvertScreenController(settings: settings, library: library)
                converter.onShowJobs = { [weak self] in self?.show(.jobs) }
                controller = converter
            case .jobs: controller = MacJobsListViewController()
            case .settings: controller = MacSettingsViewController(settings: settings, library: library)
            }
            controllers[destination] = controller
        }
        if let current = detailController {
            (current as? MacReaderViewController)?.cancelBookOpen()
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        detailContainer.addChild(controller)
        let contentView = controller.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = controller
        refreshDetailAccessibilityChildren()
    }

    func showConverter(bookID: String) {
        show(.convert)
        guard let converter = controllers[.convert] as? MacConvertScreenController else { return }
        Task { await converter.selectLibraryBook(bookID) }
    }

    func showReader(bookID: String) {
        playbackSession.cancel(ifReplacingBook: bookID)
        sidebarPresentation.select(.library)
        readerChromeHidden = false
        let reader = MacReaderViewController(
            library: library,
            settings: settings,
            player: player,
            bookmarkStore: bookmarkStore,
            onClose: { [weak self] in self?.show(.library) },
            onListen: { [weak self] in self?.playFromCurrentReaderPosition() },
            onVoiceModels: { [weak self] reader, anchor in
                self?.presentVoiceModels(bookID: bookID, from: reader, anchoredTo: anchor)
            },
            onPlaySelection: { [weak self] chapter, ratio in
                guard let self else { return }
                self.playbackSession.start(owner: self, chapterOverride: chapter, pageRatioOverride: ratio)
            },
            onPlayPDF: { [weak self] anchor in
                guard let self,
                      self.player.location.readingBookID == bookID
                else { return }
                self.playbackSession.start(owner: self, pdfAnchor: anchor)
            },
            onChromeChanged: { [weak self] hidden in
                self?.readerChromeHidden = hidden
                self?.refreshPlayerBar()
            }
        )
        reader.setBook(bookID)
        if let current = detailController {
            (current as? MacReaderViewController)?.cancelBookOpen()
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        detailContainer.addChild(reader)
        let contentView = reader.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: detailContainer.view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: detailContainer.view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: detailContainer.view.safeAreaLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: playerBar.view.topAnchor),
        ])
        detailController = reader
        refreshPlayerBar()
    }

    private func presentVoiceModels(bookID: String, from reader: NSViewController, anchoredTo anchor: NSView) {
        let request = playbackSession.voicePickerRequest(bookID: bookID, owner: self) { [weak self, weak reader] in
            guard let self, let reader else { return false }
            return self.detailController === reader
        }
        voicePicker.present(from: reader, anchor: anchor, request: request)
    }

    func startPlaybackForCurrentBook() {
        MiniPlayerDismissal().allowPlayback(bookID:
            player.location.readingBookID)
        playbackSession.start(owner: self)
    }

    /// A macOS Play tap follows the reader's visible location. The reader
    /// publishes an EPUB-indexed chapter and page ratio for both scrolling
    /// and TOC navigation, so a selected TOC chapter never resumes stale
    /// audio from a previous chapter.
    private func playFromCurrentReaderPosition() {
        // Preserve normal Pause; paused Play resolves reader movement explicitly.
        guard let bookID = player.location.readingBookID else {
            if player.snapshot == nil { startPlaybackForCurrentBook() } else { player.resume() }
            return
        }
        let chapterIndex = ReaderPlaybackPriorityChapter.index(bookID: bookID, location: player.location)
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
                let copy = player.resumeChoiceCopy(readerChapterIndex: chapterIndex)
                let alert = NSAlert()
                alert.messageText = L10n.string("player.divergence.title")
                alert.informativeText = copy.message
                alert.addButton(withTitle: copy.returnTitle)
                alert.addButton(withTitle: copy.listenTitle)
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
        player.location.pageRatio
            ?? ReaderProgressStore.read(bookId: bookID)?.offsetFraction
    }

    private func playCurrentReaderPage() {
        guard let bookID = player.location.readingBookID else { return }
        guard player.isPlaybackForReaderBook(bookID)
            || (player.snapshot != nil && library.books.first(where: { $0.id == bookID })?.lastJobId == player.snapshot?.jobId) else { return }
        if playbackSession.localPlaybackGeneration != nil
            || player.snapshot?.chapterProgress?.contains(where: { ($0.textOffset ?? 0) > 0 }) == true {
            // Partial audio needs a new Rust source range and job identity.
            playbackSession.start(owner: self)
        } else {
            player.startFromReaderPage(ReaderPlaybackPriorityChapter.index(bookID: bookID, location: player.location),
                sentenceId: player.location.sentenceID,
                sentenceOffsetRatio: readerPageRatio(bookID: bookID))
        }
    }

    private func goToReading(bookID: String) {
        guard library.books.contains(where: { $0.id == bookID }) else { return }
        if player.location.readingBookID != bookID || !(detailController is MacReaderViewController) {
            showReader(bookID: bookID)
        }
        (detailController as? MacReaderViewController)?.goToNarration()
    }

    private func refreshFullPlayer() {
        guard isViewLoaded else { return }
        if playerPresentation.showingFullPlayer {
            guard presentedViewControllers?.isEmpty != false else { return }
            let controller = MacFullPlayerViewController(
                player: player,
                library: library,
                presentation: playerPresentation,
                onStartPlayback: { [weak self] in self?.playFromCurrentReaderPosition() },
                onGoToReading: { [weak self] bookID in self?.goToReading(bookID: bookID) }
            )
            // Full-size content bounds include the titlebar; the sheet hangs below it.
            controller.preferredContentSize = view.window?.contentLayoutRect.size ?? NSSize(width: 1000, height: 700)
            fullPlayerController = controller
            presentAsSheet(controller)
        } else if let controller = fullPlayerController {
            controller.dismiss(nil)
            fullPlayerController = nil
        }
    }

    private func refreshPlayerBar() {
        syncPlayerCoverArt()
        let bookID = player.location.readingBookID
            ?? player.location.playingBookID
        let dismissal = MiniPlayerDismissal()
        let showsReaderChrome = !(detailController is MacReaderViewController) || !readerChromeHidden
        let hasReadingContext = showsReaderChrome && !dismissal.isDismissed(bookID: bookID) && (player.snapshot != nil
            || player.location.readingBookID != nil
            || library.books.contains { $0.lastOpenedAt != nil })
        // Keep the internal stack constrained to the full bar width. Toggling
        // only `isHidden` leaves the bar visible with its edge constraints
        // deactivated, which collapses the content to the leading edge and
        // creates a large empty region beside the mini-player controls.
        playerBar.setCollapsed(!hasReadingContext)
        playerBarHeightConstraint?.constant = hasReadingContext ? 60 : 0
        refreshDetailAccessibilityChildren()
    }

    private func dismissMiniPlayer() {
        MiniPlayerDismissal().dismiss(readingBookID:
            player.location.readingBookID,
            playingBookID: player.location.playingBookID)
        player.pause()
        player.persistResumePoint(force: true)
        playbackSession.cancel(stopPlayer: false)
        player.stop()
        player.clearConversionState()
        playerPresentation.dismissFullPlayer()
        refreshPlayerBar()
    }

    private func refreshDetailAccessibilityChildren() {
        guard let content = detailController?.view else { return }
        var children = [content]
        if !playerBar.view.isHidden { children.append(playerBar.view) }
        detailContainer.view.setAccessibilityChildren(children)
    }

    private func syncPlayerCoverArt() {
        let bookID = player.location.playingBookID
            ?? player.location.readingBookID
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
