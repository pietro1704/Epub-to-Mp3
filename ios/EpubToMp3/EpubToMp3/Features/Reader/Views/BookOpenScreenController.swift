#if os(iOS)
import UIKit
import UniformTypeIdentifiers

@MainActor
final class BookOpenScreenController: UIViewController, UIDocumentPickerDelegate {
    private let document: ReaderBookDocument
    private let library: LibraryStore
    private let settings: AppSettings
    private let bookmarkStore: BookmarkStore
    private let player: AudioPlayer
    private lazy var composition: ReaderViewComposition = ReaderViewComposition(
        view: view, target: self, actions: .init(
            readerTap: #selector(handleReaderTap(_:)),
            chapterForward: #selector(swipeChapterForward(_:)),
            chapterBackward: #selector(swipeChapterBackward(_:)),
            toggleChromeAccessibility: #selector(toggleChromeAccessibilityAction(_:)),
            horizontalSwipe: #selector(handleHorizontalSwipe(_:)),
            resetFlicker: #selector(resetFlickerProbe),
            toggleChrome: #selector(toggleChromeVisibility),
            pageLeft: #selector(turnPageLeft),
            pageRight: #selector(turnPageRight),
            previousChapter: #selector(uiTestPreviousChapter),
            nextChapter: #selector(uiTestNextChapter),
            retryLoading: #selector(retryLoadingBook)
        ), settings: settings, onUpdateFlicker: { [weak self] in self?.updateFlickerProbe() },
        onPDFPageReady: { [weak self] in self?.recordFirstPDFPage(wasNormalized: $0) }
    )

    private lazy var audioHighlight = ReaderAudioHighlightPresentation(
        document: document, player: player, textView: composition.textView, settings: settings)

    private lazy var narrationPairing = ReaderNarrationPairingPresentation(
        document: document, player: player, composition: composition)

    private func configureNativeReader() {
        composition.configure(isPaginatedMode: isPaginatedMode, textDelegate: annotations,
            scrollDelegate: interaction, gestureDelegate: interaction)
        textPresentation.applyReaderLayoutMode()
        annotations.installLegacySelectionActions()
        annotations.onPlayFromHere = { [weak self] _, ratio in
            guard let self else { return }
            self.onSelectionPlaybackRequested?(self.currentReaderChapterIndex, ratio)
        }
    }

    private let preparedRenderer: PreparedChapterRenderer
    private let preparedChapterStore: PreparedReaderChapterStore
    private let preparedFulltextReader: @Sendable (String) async -> EbookFulltext?
    private let preparedFulltextWriter: ReaderBookLoadSession.PreparedFulltextWriter?
    private let openStageObserver: (@Sendable (String, UInt64) -> Void)?
    private let sessionDefaults: UserDefaults
    private var reimportRequestID = UUID()
    private let deferInitialReaderGestures: Bool

    private lazy var preparedPresentation: ReaderPreparedPresentation = ReaderPreparedPresentation(
        document: document, settings: settings, renderer: preparedRenderer,
        store: preparedChapterStore, stageObserver: openStageObserver,
        viewportIsCommitted: { [weak self] in
            guard let self else { return false }
            return composition.scrollView.bounds.width > 1 && composition.scrollView.bounds.height > 1
        },
        textIsLaidOut: { [weak self] in
            self?.textPresentation.hasMeasuredTextLayout == true
        },
        send: { [weak self] event in self?.applyPreparedEvent(event) }
    )

    private func applyPreparedEvent(_ event: ReaderPreparedPresentation.Event) {
        switch event {
        case let .showChapter(index, rendering): showChapter(index, preparedRendering: rendering)
        case .layoutScrollView:
            composition.scrollView.setNeedsLayout()
            composition.scrollView.layoutIfNeeded()
        case let .scheduleHostLayout(loadingID):
            DispatchQueue.main.async { [weak self] in
                guard let self, isCurrentLoad(loadingID, bookID: document.book.id),
                      document.pendingProjectionAnchor?.loadingID == loadingID else { return }
                view.setNeedsLayout()
                view.layoutIfNeeded()
            }
        case .requestHostLayout: view.setNeedsLayout()
        case .layoutHostView:
            view.layoutIfNeeded()
        case let .restorePosition(progress):
            readingPosition.restoreReadingAnchor(ReadingAnchor(offsetFraction: CGFloat(progress.offsetFraction),
                characterOffset: progress.characterOffset))
        case .updatePageIndicator: textPresentation.updatePageIndicator()
        case .completeLoading: loadingSession.completeLoadingAfterStableTextLayoutIfNeeded()
        case let .finishLoading(id): finishLoadingAfterStableTextLayout(id)
        case let .publishTitles(payload): publishReaderChapterTitles(payload)
        case .catalogReadyForNavigation: readingPosition.revealPendingPlaybackLocation()
        case let .error(message): showLoadingError(message)
        }
    }

    private lazy var pageNavigation: ReaderPageNavigation = ReaderPageNavigation(
        view: view, scrollView: composition.scrollView, pageUnderflowGuard: composition.pageUnderflowGuard,
        pageOverflowGuard: composition.pageOverflowGuard, settings: settings,
        beforeSnapshot: { [weak self] in self?.textPresentation.updatePageOverflowGuard() }
    )

    private var isPaginatedMode: Bool { textPresentation.isPaginatedMode }

    /// Reports whether the book is currently loading (parsing/fetching
    /// fulltext), so the host screen (`MainReaderScreenController`) can
    /// hide chrome like the "Ouvir" button until content is ready.
    var onLoadStateChanged: ((Bool) -> Void)?
    var onPlaybackChapterEstimates: (([Int: TimeInterval]) -> Void)?
    var onPDFPlaybackRequested: ((PDFReadingAudioMap.Anchor) -> Void)?
    var onSelectionPlaybackRequested: ((Int, Double) -> Void)?

    /// The host owns presentation state; it only needs this content fact
    /// while it synchronizes the initial loading cover into its final viewport.
    var isLoadingBookContent: Bool { isLoadingContent }

    /// Hosts apply explicit presentation snapshots through
    /// `applyChromeVisibility`. The content surface only requests a state
    /// reset after loading or a user-driven toggle; it never derives the
    /// next state from its local layout cache.
    var onChromeVisibilityRequested: ((Bool) -> Void)?

    /// The reader's in-memory chapter is more current than persisted progress
    /// while the user is turning pages, so playback scheduling uses this
    /// value to synthesize the chapter currently on screen first.
    var currentReaderChapterIndex: Int {
        if let anchor = composition.contentSurface.pdfPresentation?.currentAnchor { return anchor.chapterIndex }
        return ReaderPlaybackAnchor.epubIndex(
            forReaderPosition: document.selectedChapter,
            in: document.fulltext?.chapters ?? []
        ) ?? document.activePreparedChapter?.chapter.zeroBasedEpubIndex ?? document.selectedChapter
    }

    func revealPlaybackLocation(_ location: ReaderPlaybackLocation) {
        readingPosition.revealPlaybackLocation(location)
    }

    /// Source metadata lets streamed playback navigate before audio is ready.
    var playbackChapterEstimates: [Int: TimeInterval] {
        let chapters = document.fulltext?.chapters
            ?? document.activePreparedChapter.map { [$0.chapter] } ?? []
        return ChapterPlaybackTimeline.estimates(for: chapters)
    }

    var playbackChapterCatalog: [(index: Int, title: String)] {
        if let chapters = composition.contentSurface.pdfPresentation?.audioMap?.chapters {
            return chapters.enumerated().map { ($0.offset, $0.element.name) }
        }
        if let fulltext = document.fulltext {
            return fulltext.chapters.map { ($0.zeroBasedEpubIndex, $0.displayTitle) }
        }
        return (document.activePreparedChapter?.catalogChapters ?? []).map {
            (max(0, $0.index - 1), $0.name ?? L10n.string("player.chapter", $0.index))
        }
    }
var onListenRequested: (() -> Void)?
var onVoiceModelsRequested: (() -> Void)?
private lazy var toolBar = ReaderToolBar(defaults: sessionDefaults) { [weak self] tool in
    guard let self else { return }
    switch tool {
    case .appearance: self.presentReaderSettings()
    case .contents: self.presentTOC()
    case .search: self.promptSearch()
    case .footnotes: self.showFootnotes()
    case .voiceModels: self.onVoiceModelsRequested?()
    case .listen:
        // A PDF starts at the visible page and fails closed when it has no narration text.
        if let pdf = self.composition.contentSurface.pdfPresentation { pdf.playFromCurrentPosition() }
        else { self.onListenRequested?() }
    }
}

/// Stable native bar items let the direct-access tool update without replacing the host bar.
func installNavigationBarButtonItems(in item: UINavigationItem?) { toolBar.install(in: item) }
    private static let reimportTypes: [UTType] = SupportedImportTypes.all

    init(book initialBook: BookEntity, library: LibraryStore, settings: AppSettings, bookmarkStore: BookmarkStore,
         player: AudioPlayer, preparedRenderer: PreparedChapterRenderer? = nil,
         preparedChapterStore: PreparedReaderChapterStore = .shared,
         preparedFulltextReader: @escaping @Sendable (String) async -> EbookFulltext? = { id in
            await Task.detached(priority: .userInitiated) { LocalFulltextCache.read(bookId: id) }.value
         },
         preparedFulltextWriter: ReaderBookLoadSession.PreparedFulltextWriter? = nil,
         openStageObserver: (@Sendable (String, UInt64) -> Void)? = nil,
         sessionDefaults: UserDefaults = .standard,
         deferInitialReaderGestures: Bool = true) {
        self.document = ReaderBookDocument(book: initialBook)
        document.openJourney.stageObserver = openStageObserver
        self.library = library
        self.settings = settings
        self.bookmarkStore = bookmarkStore
        self.player = player
        self.preparedRenderer = preparedRenderer ?? .shared
        self.preparedChapterStore = preparedChapterStore
        self.preparedFulltextReader = preparedFulltextReader
        self.preparedFulltextWriter = preparedFulltextWriter
        self.openStageObserver = openStageObserver
        self.sessionDefaults = sessionDefaults
        self.deferInitialReaderGestures = deferInitialReaderGestures
        super.init(nibName: nil, bundle: nil)
        // READING-PREFERENCES: the book's own reading preferences apply while it is open, from the first render.
        settings.enterBookScope(initialBook.id)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        observeOpenStage("reader_view_did_load_started")
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNativeReader()
        settingsPresentation.applyReaderColors()
        settingsPresentation.observe()
        audioHighlight.observe()
        narrationPairing.observe()
        interaction.onViewportChange = { [weak self] in self?.narrationPairing.refresh() }
        loadBook()
        observeOpenStage("reader_view_did_load_completed")
    }

    override func viewDidAppear(_ animated: Bool) {
        observeOpenStage("reader_view_did_appear_started")
        super.viewDidAppear(animated)
        observeOpenStage("reader_view_did_appear_completed")
    }

    override func willMove(toParent parent: UIViewController?) {
        if parent == nil, isViewLoaded {
            annotations.cancelSearch()
            audioHighlight.stop()
            narrationPairing.stop()
        }
        if parent != nil, isViewLoaded { audioHighlight.observe(); narrationPairing.observe() }
        super.willMove(toParent: parent)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
              traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) else { return }
        settingsPresentation.applyReaderColors()
    }

    func update(book incomingBook: BookEntity) {
        reimportRequestID = UUID()
        readingPosition.cancelPendingPlaybackLocation()
        document.book = incomingBook
        settings.enterBookScope(incomingBook.id)
        document.hasRestoredInitialPosition = false
        loadBook()
    }

    /// Applies the root-owned chrome snapshot locally. The reader never
    /// chooses this state: it only updates its own safe-area constraints.
    @discardableResult
    func applyChromeVisibility(_ isHidden: Bool) -> Bool {
        guard textPresentation.chromeHidden != isHidden else { return false }
        textPresentation.chromeHidden = isHidden
        textPresentation.applyReaderLayoutMode()
        return true
    }

    private lazy var textPresentation: ReaderTextPresentation = ReaderTextPresentation(
        document: document, composition: composition, settings: settings, player: player,
        renderer: preparedRenderer, preparedPresentation: preparedPresentation,
        readingPosition: readingPosition, annotations: annotations, diagnostics: diagnostics,
        stageObserver: openStageObserver,
        onFootnotesAvailabilityChanged: { [weak self] in self?.toolBar.hasFootnotes = $0 },
        applyColors: { [weak self] in self?.settingsPresentation.applyReaderColors() },
        showError: { [weak self] in self?.showLoadingError($0) },
        completeLoading: { [weak self] in self?.loadingSession.completeLoadingAfterStableTextLayoutIfNeeded() }
    )
    /// Paginated layout ends the text above the mini player (the other screens use the same clearance).
    private let miniPlayerClearance = MiniPlayerScrollClearance()
    private var rootContainer: IOSRootContainerController? {
        var ancestor = parent
        while let current = ancestor {
            if let root = current as? IOSRootContainerController { return root }
            ancestor = current.parent
        }
        return nil
    }

    override func viewDidLayoutSubviews() {
        observeOpenStage("reader_view_did_layout_started")
        super.viewDidLayoutSubviews()
        if settings.readerLayout == .paginated, let root = rootContainer {
            miniPlayerClearance.update(self, occlusion: root.readerMiniPlayerReservation(in: view))
        } else { miniPlayerClearance.update(self, occlusion: nil) }
        textPresentation.layoutCommittedViewport()
    }
    private func showChapter(_ index: Int, preparedRendering: NSAttributedString? = nil) {
        audioHighlight.clear()
        textPresentation.showChapter(index, preparedRendering: preparedRendering)
        audioHighlight.refresh()
        narrationPairing.refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        readingPosition.persistReadingProgress()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The reader is closed (not just covered by a sheet): the default applies to the next book.
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true { settings.leaveBookScope() }
    }

    private typealias ReadingAnchor = ReaderReadingPosition.ReadingAnchor
    private lazy var readingPosition: ReaderReadingPosition = ReaderReadingPosition(
        document: document, composition: composition,
        facts: { [unowned self] in .init(chromeHidden: textPresentation.chromeHidden,
            isPaginated: isPaginatedMode, isLoading: isLoadingContent, layoutResult: textPresentation.paginatedLayoutResult) },
        send: { [weak self] event in
            guard let self else { return }
            switch event {
            case .requestTextLayoutRefresh: textPresentation.requestTextLayoutRefresh()
            case .updatePaginationProbe: updatePaginationProbe()
            case .updatePageIndicator: textPresentation.updatePageIndicator()
            case let .showChapter(index): showChapter(index)
            case .updateTextHeightForCurrentLayout: textPresentation.updateTextHeightForCurrentLayout()
            case let .prepareProjection(ordinal): preparedPresentation.prepareChapterProjection(ordinal: ordinal)
            }
        }
    )
    private var isViewportTransitioning: Bool { readingPosition.isViewportTransitioning }
    private var pendingViewportAnchor: ReadingAnchor? { readingPosition.pendingViewportAnchor }
    func prepareForViewportTransition() { readingPosition.prepareForViewportTransition() }
    func completeViewportTransition() { readingPosition.completeViewportTransition() }

    private lazy var bookLoadSession: ReaderBookLoadSession = ReaderBookLoadSession(
        document: document, settings: settings, renderer: preparedRenderer,
        store: preparedChapterStore, preparedPresentation: preparedPresentation,
        readFulltext: preparedFulltextReader,
        writeFulltext: preparedFulltextWriter,
        openBook: { [library] in try await library.openBookFileAsync(id: $0) },
        stageObserver: openStageObserver,
        send: { [weak self] event in
            guard let self else { return }
            switch event {
            case .cancelJourney: document.openJourney.cancelActiveBookOpenJourney()
            case .showLoading: loadingSession.showLoadingOverlay()
            case .hideLoading: loadingSession.hideLoadingOverlay()
            case .loadFixture: loadingSession.loadUITestFixture()
            case let .showPDF(url): showPDF(url)
            case let .failure(message):
                composition.textView.text = ""
                showLoadingError(message)
            }
        }
    )

    private func loadBook() {
        guard isViewLoaded else { return }
        toolBar.hasFootnotes = false
        loadingSession.cancelFixture()
        bookLoadSession.loadBook()
    }
    private func observeOpenStage(_ name: String) {
        let timestamp = DispatchTime.now().uptimeNanoseconds
        openStageObserver?(name, timestamp)
    }

    private lazy var loadingSession: ReaderLoadingSession = ReaderLoadingSession(
        document: document, composition: composition, settings: settings,
        textPresentation: textPresentation, readingPosition: readingPosition, observation: document.openJourney,
        deferInitialReaderGestures: deferInitialReaderGestures, stageObserver: openStageObserver,
        scheduleReaderSettingsUpdate: { [weak self] in self?.settingsPresentation.scheduleReaderSettingsUpdate() },
        onLoadStateChanged: { [weak self] in self?.onLoadStateChanged?($0) },
        onChromeVisibilityRequested: { [weak self] in self?.onChromeVisibilityRequested?($0) }
    )
    private var isLoadingContent: Bool { loadingSession.isLoadingContent }
    private var isDeferringReaderGestures: Bool { loadingSession.isDeferringReaderGestures }
    private func showLoadingError(_ message: String) { loadingSession.showLoadingError(message) }
    private func finishLoadingAfterStableTextLayout(_ id: UUID) { loadingSession.finishLoadingAfterStableTextLayout(id) }
    private func recordFirstPDFPage(wasNormalized: Bool) { document.openJourney.recordFirstPDFPage(wasNormalized: wasNormalized) }

    private func isCurrentLoad(_ loadingID: UUID, bookID: String) -> Bool {
        document.isCurrentLoad(loadingID, bookID: bookID)
    }

    @objc private func retryLoadingBook() {
        document.hasRestoredInitialPosition = false
        loadBook()
    }

    private func publishReaderChapterTitles(_ payload: EbookFulltext) {
        onPlaybackChapterEstimates?(ChapterPlaybackTimeline.estimates(for: payload.chapters))
        for chapter in payload.chapters {
            player.updateReaderChapterTitle(chapter.displayTitle, for: chapter.zeroBasedEpubIndex)
        }
    }

    private lazy var diagnostics: ReaderDiagnosticsPresentation = ReaderDiagnosticsPresentation(document: document, composition: composition)
    @objc private func resetFlickerProbe() { diagnostics.resetFlickerProbe() }
    private func updateFlickerProbe() { diagnostics.updateFlickerProbe() }
    private func updatePaginationProbe() {
        diagnostics.updatePaginationProbe(layoutResult: textPresentation.paginatedLayoutResult,
            pageOffsets: textPresentation.paginatedPageOffsets, chromeHidden: textPresentation.chromeHidden)
    }

    @objc private func toggleChromeVisibility() {
        // The host owns the whole constraint transaction (navigation, reader
        // viewport and mini player). A second chrome tap is accepted as a new
        // target state; page turns remain blocked until that host transaction
        // has supplied final geometry.
        composition.textView.accessibilityHint = L10n.string("reader.toggleControls")
        prepareForViewportTransition()
        onChromeVisibilityRequested?(!textPresentation.chromeHidden)
    }

    @objc private func toggleChromeAccessibilityAction(_ action: UIAccessibilityCustomAction) -> Bool {
        toggleChromeVisibility()
        return true
    }

    private(set) lazy var contentsPresentation: ReaderContentsPresentation = ReaderContentsPresentation(
        document: document, composition: composition, library: library, settings: settings, player: player,
        readingPosition: readingPosition, textPresentation: textPresentation,
        present: { [weak self] in self?.present($0, animated: true) }
    )
    @objc private func presentTOC() { contentsPresentation.presentTOC() }

    private lazy var settingsPresentation: ReaderSettingsPresentation = ReaderSettingsPresentation(
        document: document, composition: composition, settings: settings,
        textPresentation: textPresentation, readingPosition: readingPosition,
        isLoading: { [weak self] in self?.isLoadingContent ?? true },
        applyInterfaceStyle: { [weak self] style in
            guard let self, overrideUserInterfaceStyle != style else { return }
            overrideUserInterfaceStyle = style
        },
        present: { [weak self] in self?.present($0, animated: true) },
        refreshProbe: { [weak self] in self?.updatePaginationProbe() }
    )
    @objc private func presentReaderSettings() { settingsPresentation.presentReaderSettings() }

    private lazy var interaction: ReaderInteraction = ReaderInteraction(
        document: document, composition: composition, settings: settings,
        textPresentation: textPresentation, readingPosition: readingPosition, pageNavigation: pageNavigation,
        isLoadingContent: { [weak self] in self?.isLoadingContent ?? true },
        isDeferringReaderGestures: { [weak self] in self?.isDeferringReaderGestures ?? true },
        toggleChromeVisibility: { [weak self] in self?.toggleChromeVisibility() },
        refreshProbe: { [weak self] in self?.updatePaginationProbe() }
    )
    @objc private func handleReaderTap(_ gesture: UITapGestureRecognizer) { interaction.handleReaderTap(gesture) }
    @objc private func handleHorizontalSwipe(_ gesture: UIPanGestureRecognizer) { interaction.handleHorizontalSwipe(gesture) }
    @objc private func turnPageLeft() { interaction.turnPageLeft() }
    @objc private func turnPageRight() { interaction.turnPageRight() }
    @objc private func swipeChapterForward(_ gesture: UISwipeGestureRecognizer) { interaction.swipeChapterForward(gesture) }
    @objc private func swipeChapterBackward(_ gesture: UISwipeGestureRecognizer) { interaction.swipeChapterBackward(gesture) }
    @objc private func uiTestPreviousChapter() { interaction.uiTestPreviousChapter() }
    @objc private func uiTestNextChapter() { interaction.uiTestNextChapter() }

    nonisolated static func allowsReaderNavigation(
        isDeferringReaderGestures: Bool,
        isLoadingOverlayHidden: Bool,
        isViewportTransitioning: Bool = false
    ) -> Bool {
        !isDeferringReaderGestures && isLoadingOverlayHidden && !isViewportTransitioning
    }

    private lazy var annotations: ReaderAnnotationsPresentation = ReaderAnnotationsPresentation(
        document: document, composition: composition, bookmarkStore: bookmarkStore, settings: settings,
        persistProgress: { [weak self] in self?.readingPosition.persistReadingProgress() },
        showChapter: { [weak self] in self?.showChapter($0) },
        present: { [weak self] in self?.present($0, animated: true) },
        isCurrentBook: { [weak self] in
            guard let self else { return false }
            return sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == document.book.id
        }
    )
    @objc private func showFootnotes() { annotations.showFootnotes() }
    @objc private func promptSearch() {
        if let pdf = composition.contentSurface.pdfPresentation { pdf.promptSearch() }
        else { annotations.promptSearch() }
    }

    private func showPDF(_ url: URL) {
        composition.contentSurface.configurePDF(.init(bookID: document.book.id, settings: settings,
            player: player, defaults: sessionDefaults, toggleChrome: { [weak self] in self?.toggleChromeVisibility() },
            playFrom: { [weak self] in self?.onPDFPlaybackRequested?($0) },
            positionChanged: { [weak self] anchor, page, total in
                guard let self else { return }
                if let anchor { document.selectedChapter = anchor.chapterIndex }
                let position = L10n.string("reader.pageOf", page, total)
                composition.pageIndicator.text = position
                composition.pageIndicator.accessibilityValue = position
                composition.pageIndicator.isHidden = !settings.readerShowPageNumbers || textPresentation.chromeHidden
                composition.pageIndicator.alpha = composition.pageIndicator.isHidden ? 0 : 1
            }))
        composition.contentSurface.mount(.pdf(url))
        textPresentation.applyReaderLayoutMode()
    }

    func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.reimportTypes, asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let request = UUID()
        reimportRequestID = request
        let originalBookID = document.book.id
        let originalSelection = sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        Task { [weak self] in
            guard let self else { return }
            defer { if reimportRequestID == request { reimportRequestID = UUID() } }
            do {
                let imported = try await library.importBookAsync(from: url)
                guard !Task.isCancelled, reimportRequestID == request, document.book.id == originalBookID,
                      sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == originalSelection else { return }
                document.book = imported
                ReaderSessionState.setCurrentlyReading(bookID: imported.id, defaults: sessionDefaults)
                document.hasRestoredInitialPosition = false
                loadBook()
            } catch {
                guard !Task.isCancelled, reimportRequestID == request, document.book.id == originalBookID,
                      sessionDefaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey) == originalSelection else { return }
                let alert = UIAlertController(title: L10n.string("bookOpen.error"), message: AppErrorReporter.message(error, context: #function), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }
}

#endif
