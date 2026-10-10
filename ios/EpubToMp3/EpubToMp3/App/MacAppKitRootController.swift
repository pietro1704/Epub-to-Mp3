#if os(macOS)
import AppKit
import Combine

@MainActor
final class MacAppKitRootController: NSSplitViewController, NSToolbarDelegate {
    static let sidebarToolbarItemIdentifier = NSToolbarItem.Identifier("app.toggleSidebar")
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
    private var isStartingLocalPlayback = false
    private var localPlaybackGeneration: String?
    private var localPlaybackChapters: [JobSnapshot.Chapter] = []
    private var localPlaybackControl: ConverterPlaybackControl?

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
        playerPresentation: PlayerPresentation? = nil
    ) {
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
        let sidebar = NSSplitViewItem(sidebarWithViewController: makeSidebar())
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
            .sink { [weak self] _ in self?.refreshFullPlayer() }
            .store(in: &cancellables)
        player.$activeStreamingChapterIndex
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] chapterIndex in
                guard let self, self.localPlaybackGeneration != nil,
                      let control = self.localPlaybackControl else { return }
                control.updatePlaybackWindow(currentChapter: chapterIndex, chaptersAhead: 1)
                _ = control.prioritize(chapterIndex: chapterIndex)
            }
            .store(in: &cancellables)
        restoreLocalPlaybackControls()
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
    private func restoreLocalPlaybackControls() {
        let bookID = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey)
            ?? UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        guard let bookID else { return }
        let epubChapterIndex = UserDefaults.standard.object(
            forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey
        ) as? Int ?? 0
        Task { [weak self] in
            guard let self else { return }
            let embeddedSnapshot = try? await LocalAudioArtifactStore.shared.playableSnapshot(
                bookID: bookID,
                engine: "edge",
                voice: "auto",
                language: nil
            )
            let remoteSnapshot = library.books.first(where: { $0.id == bookID })?.lastJobId
                .flatMap(DownloadManager.localPlaybackSnapshot(jobId:))
            guard let snapshot = embeddedSnapshot ?? remoteSnapshot else {
                return
            }
            player.play(
                snapshot: snapshot,
                startingAt: AudioPlayer.restoredPlayableChapterOffset(
                    snapshot: snapshot,
                    persistedEpubChapterIndex: epubChapterIndex
                ),
                restoreAutoplay: false
            )
            refreshPlayerBar()
        }
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

    @objc func focusLibrarySearch(_ sender: Any?) {
        show(.library)
        (controllers[.library] as? MacLibraryViewController)?.focusSearch()
    }

    private func makeSidebar() -> NSViewController {
        let controller = NSViewController()
        let title = NSTextField(labelWithString: L10n.string("app.name"))
        title.font = .boldSystemFont(ofSize: 16)
        let menu = NSStackView()
        menu.orientation = .vertical
        menu.alignment = .leading
        menu.spacing = 4
        for destination in Destination.allCases {
            let button = NSButton(title: destination.title, target: self, action: #selector(sidebarButtonActivated(_:)))
            button.tag = destination.rawValue
            button.alignment = .left
            button.image = NSImage(systemSymbolName: destination.icon, accessibilityDescription: destination.title)
            button.imagePosition = .imageLeading
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
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
        let stack = NSStackView(views: [title, menu, spacer])
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
        guard !isStartingLocalPlayback else { return }
        guard let bookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey),
              let book = library.books.first(where: { $0.id == bookID }) else { return }
        isStartingLocalPlayback = true
        Task { [weak self] in
            guard let self else { return }
            defer { isStartingLocalPlayback = false }
            let jobID = UUID().uuidString
            do {
                let url = try await library.openBookFileAsync(id: book.id)
                localPlaybackGeneration = jobID
                localPlaybackChapters.removeAll()
                let chapterStart = Int32(exactly: ReaderPlaybackPriorityChapter.index(bookID: book.id)) ?? 0
                let playbackControl = try RustConversionCoordinator.makePlaybackControl()
                playbackControl.updatePlaybackWindow(
                    currentChapter: Int(chapterStart),
                    chaptersAhead: 1
                )
                localPlaybackControl = playbackControl
                let pending = JobSnapshot(
                    jobId: jobID,
                    state: "running",
                    bookTitle: book.resolvedTitle,
                    bookAuthor: book.author,
                    coverUrl: nil,
                    coverMimeType: nil,
                    engine: "edge",
                    voice: nil,
                    language: nil,
                    progressPercent: 0,
                    chaptersTotal: nil,
                    chaptersCompleted: 0,
                    chapterProgress: [],
                    outputs: nil,
                    logUrl: nil,
                    error: nil,
                    lastActivityAt: Date().timeIntervalSince1970
                )
                player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
                player.isConverting = true
                player.resume()
                let chunkDelivery = StreamingPlaybackChunkDelivery(player: player)
                let result = try await RustConversionCoordinator.executeStreaming(
                    bookURL: url,
                    jobID: jobID,
                    chapterStart: chapterStart,
                    chapterEnd: -1,
                    control: playbackControl,
                    onProgress: { [weak self] event in
                        guard let self,
                              self.localPlaybackGeneration == jobID,
                              event.state == "running",
                              let snapshot = self.player.snapshot,
                              snapshot.jobId == jobID else { return }
                        self.player.updateSnapshot(event.updating(snapshot))
                    },
                    onChapterCompleted: { [weak self] event in
                        guard let self, self.localPlaybackGeneration == event.jobId else { return }
                        let activeChapter = self.player.activeStreamingChapterIndex
                            ?? Int(chapterStart)
                        guard event.chapterIndex >= activeChapter,
                              event.chapterIndex <= activeChapter + 1 else { return }
                        let firstPlayableChapter = self.localPlaybackChapters.isEmpty
                        let chapter = event.playableChapter
                        if let existing = self.localPlaybackChapters.firstIndex(where: { $0.index == chapter.index }) {
                            self.localPlaybackChapters[existing] = chapter
                        } else {
                            self.localPlaybackChapters.append(chapter)
                        }
                        self.localPlaybackChapters.sort { $0.index < $1.index }
                        self.player.updateSnapshot(
                            event.snapshot(chapters: self.localPlaybackChapters)
                        )
                        if firstPlayableChapter {
                            self.playerPresentation.showFullPlayer()
                        }
                    },
                    onAudioChunk: { chapterIndex, chunkIndex, data in
                        return chunkDelivery.enqueue(
                            data,
                            chapterIndex: chapterIndex,
                            chunkIndex: chunkIndex,
                            isCurrent: { [weak self] in
                                guard let self else { return false }
                                let currentChapter = self.player.activeStreamingChapterIndex
                                    ?? Int(chapterStart)
                                return self.localPlaybackGeneration == jobID
                                    && self.player.snapshot?.jobId == jobID
                                    && chapterIndex >= currentChapter
                                    && chapterIndex <= currentChapter + 1
                            },
                            onAccepted: {}
                        )
                    }
                )
                let snapshot = try result.snapshot()
                library.recordConversion(jobId: result.jobID, for: book.id)
                localPlaybackGeneration = nil
                localPlaybackControl = nil
                await MainActor.run {
                    self.player.finishStreaming(snapshot: snapshot)
                    self.playerPresentation.showFullPlayer()
                }
            } catch {
                localPlaybackGeneration = nil
                localPlaybackControl?.cancel()
                localPlaybackControl = nil
                if let current = player.snapshot, current.jobId == jobID {
                    player.finishStreaming(snapshot: JobSnapshot(
                        jobId: current.jobId,
                        state: "failed",
                        bookTitle: current.bookTitle,
                        bookAuthor: current.bookAuthor,
                        coverUrl: current.coverUrl,
                        coverMimeType: current.coverMimeType,
                        engine: current.engine,
                        voice: current.voice,
                        language: current.language,
                        progressPercent: current.progressPercent,
                        chaptersTotal: current.chaptersTotal,
                        chaptersCompleted: current.chaptersCompleted,
                        chapterProgress: current.chapterProgress,
                        outputs: current.outputs,
                        logUrl: current.logUrl,
                        error: error.localizedDescription,
                        lastActivityAt: Date().timeIntervalSince1970
                    ))
                }
                let alert = NSAlert()
                alert.messageText = L10n.string("bookDetail.listenStart")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    /// A macOS Play tap follows the reader's visible location. The reader
    /// publishes an EPUB-indexed chapter and page ratio for both scrolling
    /// and TOC navigation, so a selected TOC chapter never resumes stale
    /// audio from a previous chapter.
    private func playFromCurrentReaderPosition() {
        // Transport Play after a deliberate pause resumes the existing item,
        // even when the reader still publishes the chapter's opening page.
        if player.hasPausedPlaybackToResume {
            player.resume()
            return
        }
        guard let bookID = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) else {
            if player.snapshot == nil { startPlaybackForCurrentBook() } else { player.resume() }
            return
        }
        let chapterIndex = ReaderPlaybackPriorityChapter.index(bookID: bookID)
        let pageRatio = readerPageRatio(bookID: bookID)
        if let snapshot = player.snapshot,
           snapshot.state == "finished" || snapshot.playableChapters.contains(where: { $0.index == chapterIndex }) {
            player.startFromReaderPage(chapterIndex, sentenceOffsetRatio: pageRatio)
        } else {
            startPlaybackForCurrentBook()
        }
    }

    private func readerPageRatio(bookID: String) -> Double? {
        UserDefaults.standard.object(forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) as? Double
            ?? ReaderProgressStore.read(bookId: bookID)?.offsetFraction
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
        cancellable = player.objectWillChange.sink { [weak self] _ in self?.refresh() }
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
        let bookTitle = book?.resolvedTitle ?? player.snapshot?.bookTitle ?? L10n.string("player.nothingPlaying")
        titleLabel.stringValue = player.snapshot == nil ? bookTitle : player.effectiveChapterTitle
        chapterLabel.stringValue = player.snapshot == nil ? "" : bookTitle
        etaLabel.stringValue = player.durationSeconds > 0
            ? L10n.string("player.remaining", formatTime(player.playbackDurationSeconds - player.playbackPositionSeconds))
            : ""
        coverView.image = book?.coverPNG.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)
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
        titleLabel.font = .boldSystemFont(ofSize: 24)
        titleLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        elapsedLabel.textColor = .secondaryLabelColor
        remainingLabel.textColor = .secondaryLabelColor
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged(_:))
        progressSlider.isContinuous = false
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
        background.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            coverView.widthAnchor.constraint(equalToConstant: 280),
            coverView.heightAnchor.constraint(equalToConstant: 280),
            timeControls.widthAnchor.constraint(equalToConstant: 380),
            progressSlider.widthAnchor.constraint(equalToConstant: 300),
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

private extension NSViewController {
    func removeChildControllers() {
        children.forEach { $0.removeFromParent() }
    }
}
#endif
