#if os(macOS) && !targetEnvironment(simulator)
import AppKit

@MainActor
final class MacReaderViewController: NSViewController {
    private let document = MacReaderDocument()
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let bookmarkStore: BookmarkStore
    private let preparedRenderer: PreparedChapterRenderer
    private let preparedChapterStore: PreparedReaderChapterStore
    private let preparedFulltextReader: @Sendable (String) async -> EbookFulltext?
    private let preparedFulltextWriter: @Sendable (EbookFulltext, String) -> Void
    private let openStageObserver: (@Sendable (String, UInt64) -> Void)?
    private let initialPositionScheduler: (@escaping @MainActor () -> Void) -> Void
    private let onClose: () -> Void
    private lazy var composition: MacReaderViewComposition = MacReaderViewComposition(
        view: view, target: self, settings: settings,
        actions: .init(close: #selector(closeReader), contents: #selector(showTOC(_:)),
            search: #selector(promptSearch), settings: #selector(showSettings(_:)),
            retryLoading: #selector(retryLoadingBook)),
        cancelJourney: { [weak self] in self?.cancelActiveBookOpenJourney() },
        onLink: { [weak self] in self?.handleReaderLink($0, linkText: $1) ?? true },
        onKeyDown: { [weak self] in self?.handleKeyboardEvent($0) ?? false },
        onPageTap: { [weak self] in self?.scrollPage(forward: $0) },
        onBuildSelectionMenu: { [weak self] in self?.buildSelectionMenuItems(range: $0) ?? [] }
    )
    private func configureReader() { composition.configure() }
    private func showLoading(for book: BookEntity) { composition.loading.showLoading(for: book) }
    private func hideLoading() { composition.loading.hideLoading() }
    private func showLoadingError(_ error: Error) { composition.loading.showLoadingError(error) }

    private var chaptersTable: NSTableView { composition.chaptersTable }
    private var textView: MacReaderTextView { composition.textView }
    private var comicPageImageView: NSImageView { composition.comicPageImageView }
    private var contentScrollView: NSScrollView { composition.contentScrollView }
    private var bookTitleLabel: NSTextField { composition.bookTitleLabel }
    private var chapterTitleLabel: NSTextField { composition.chapterTitleLabel }
    private var statusLabel: NSTextField { composition.statusLabel }
    private var settingsPopover: NSPopover { composition.settingsPopover }

    init(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        bookmarkStore: BookmarkStore,
        onClose: @escaping () -> Void,
        preparedRenderer: PreparedChapterRenderer? = nil,
        preparedChapterStore: PreparedReaderChapterStore = .shared,
        preparedFulltextReader: @escaping @Sendable (String) async -> EbookFulltext? = { id in
            await Task.detached(priority: .userInitiated) { LocalFulltextCache.read(bookId: id) }.value
        },
        preparedFulltextWriter: @escaping @Sendable (EbookFulltext, String) -> Void = { payload, id in
            LocalFulltextCache.save(payload, bookId: id)
        },
        openStageObserver: (@Sendable (String, UInt64) -> Void)? = nil,
        initialPositionScheduler: @escaping (@escaping @MainActor () -> Void) -> Void = { operation in
            DispatchQueue.main.async { operation() }
        }
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.bookmarkStore = bookmarkStore
        self.onClose = onClose
        self.preparedRenderer = preparedRenderer ?? .shared
        self.preparedChapterStore = preparedChapterStore
        self.preparedFulltextReader = preparedFulltextReader
        self.preparedFulltextWriter = preparedFulltextWriter
        self.openStageObserver = openStageObserver
        self.initialPositionScheduler = initialPositionScheduler
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let surface = MacReaderSurfaceView()
        surface.onKeyDown = { [weak self] event in
            self?.handleKeyboardEvent(event) ?? false
        }
        surface.onPageTap = { [weak self] forward in
            self?.scrollPage(forward: forward)
            return true
        }
        surface.onAppearanceChange = { [weak self] in
            self?.applyCurrentReaderTheme()
        }
        view = surface
        view.wantsLayer = true
    }

    override func viewDidAppear() {
        observeOpenStage("reader_view_did_appear_started")
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
        observeOpenStage("reader_view_did_appear_completed")
    }

    override func viewDidLayout() {
        observeOpenStage("reader_view_did_layout_started")
        super.viewDidLayout()
        if contentScrollView.documentView === textView {
            MacReaderTextLayout.fit(textView, in: contentScrollView)
        }
        observeOpenStage("reader_view_did_layout_completed")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        persistReadingProgress()
    }

    override func viewDidLoad() {
        observeOpenStage("reader_view_did_load_started")
        super.viewDidLoad()
        observeOpenStage("reader_configure_started")
        configureReader()
        observeOpenStage("reader_configure_completed")
        textPresentation.observeAppearance()
        loadCurrentBook()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: contentScrollView
        )
        observeOpenStage("reader_view_did_load_completed")
    }

    func setBook(_ bookID: String?) {
        UserDefaults.standard.set(bookID, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        loadCurrentBook()
    }

    private lazy var contentsPresentation: MacReaderContentsPresentation = MacReaderContentsPresentation(
        document: document, composition: composition,
        persistProgress: { [weak self] in self?.persistReadingProgress() },
        showChapter: { [weak self] in self?.showChapter($0) }
    )
    @objc private func showTOC(_ sender: NSButton) { contentsPresentation.showTOC(sender) }
    func numberOfRows(in tableView: NSTableView) -> Int { contentsPresentation.numberOfRows(in: tableView) }
    private func selectCurrentTOCRow() { contentsPresentation.selectCurrentTOCRow() }

    private lazy var settingsPresentation: MacReaderSettingsPresentation = MacReaderSettingsPresentation(settings: settings, popover: composition.settingsPopover)
    @objc private func showSettings(_ sender: NSButton) { settingsPresentation.showSettings(sender) }

    private lazy var openObservation: MacReaderOpenObservation = MacReaderOpenObservation(document: document, stageObserver: openStageObserver)
    private func cancelActiveBookOpenJourney() { openObservation.cancelActiveBookOpenJourney() }
    private lazy var bookLoad: MacReaderBookLoad = MacReaderBookLoad(
        document: document, library: library, settings: settings,
        renderer: preparedRenderer, store: preparedChapterStore,
        readFulltext: preparedFulltextReader, writeFulltext: preparedFulltextWriter,
        textPresentation: textPresentation, observation: openObservation, stageObserver: openStageObserver,
        send: { [weak self] in self?.applyLoadEvent($0) }
    )
    private func loadCurrentBook() {
        guard isViewLoaded else { return }
        bookLoad.loadCurrentBook()
    }
    private func applyLoadEvent(_ event: MacReaderBookLoad.Event) {
        switch event {
        case .resetTextSurface: contentScrollView.documentView = textView
        case .empty:
            bookTitleLabel.stringValue = L10n.string("library.empty.title")
            chapterTitleLabel.stringValue = ""
            statusLabel.stringValue = L10n.string("reader.selectBook")
            textView.string = ""
            chaptersTable.reloadData()
            hideLoading()
        case let .warmHeader(book, count):
            bookTitleLabel.stringValue = book.resolvedTitle
            chapterTitleLabel.stringValue = ""
            statusLabel.stringValue = L10n.string("reader.chapterCount", count)
            chaptersTable.reloadData()
        case let .clearForLoad(book):
            textView.string = ""
            comicPageImageView.image = nil
            chaptersTable.reloadData()
            bookTitleLabel.stringValue = book.resolvedTitle
            chapterTitleLabel.stringValue = ""
            statusLabel.stringValue = L10n.string("reader.loading")
        case let .showLoading(book): showLoading(for: book)
        case .hideLoading: hideLoading()
        case .reloadContents: chaptersTable.reloadData()
        case .selectCurrentContents: selectCurrentTOCRow()
        case let .chapterCount(count): statusLabel.stringValue = L10n.string("reader.chapterCount", count)
        case let .selectRow(row): chaptersTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        case let .failure(error):
            statusLabel.stringValue = error.localizedDescription
            textView.string = ""
            showLoadingError(error)
        }
    }

    @objc private func retryLoadingBook() {
        loadCurrentBook()
    }

    private lazy var annotations: MacReaderAnnotationsPresentation = MacReaderAnnotationsPresentation(
        document: document, composition: composition, bookmarkStore: bookmarkStore,
        persistProgress: { [weak self] in self?.persistReadingProgress() },
        showChapter: { [weak self] in self?.showChapter($0) }
    )
    private func handleReaderLink(_ url: URL, linkText: String) -> Bool { annotations.handleReaderLink(url, linkText: linkText) }
    private func buildSelectionMenuItems(range: NSRange) -> [NSMenuItem] { annotations.buildSelectionMenuItems(range: range) }
    @objc private func promptSearch() { annotations.promptSearch() }
    @objc private func showFootnotes() { annotations.showFootnotes() }

    @objc private func closeReader() { onClose() }

    private lazy var textPresentation: MacReaderTextPresentation = MacReaderTextPresentation(
        document: document, composition: composition, settings: settings, renderer: preparedRenderer,
        initialPositionScheduler: initialPositionScheduler, stageObserver: openStageObserver,
        repaintSavedHighlights: { [weak self] in self?.annotations.repaintSavedHighlights(chapterIndex: $0) },
        prepareChapterProjection: { [weak self] in self?.bookLoad.prepareChapterProjection(bookID: $0, ordinal: $1) },
        selectCurrentTOCRow: { [weak self] in self?.contentsPresentation.selectCurrentTOCRow() },
        closeReader: { [weak self] in self?.onClose() }
    )
    private func applyCurrentReaderTheme() {
        guard isViewLoaded else { return }
        textPresentation.applyCurrentReaderTheme()
    }
    private func showChapter(_ index: Int, scrollToEnd: Bool = false) {
        textPresentation.showChapter(index, scrollToEnd: scrollToEnd)
    }
    private func persistReadingProgress() { textPresentation.persistReadingProgress() }
    private func handleKeyboardEvent(_ event: NSEvent) -> Bool { textPresentation.handleKeyboardEvent(event) }
    private func scrollPage(forward: Bool) { textPresentation.scrollPage(forward: forward) }
    @objc private func handleScrollDidEndLiveScroll(_ notification: Notification) { textPresentation.handleScrollDidEndLiveScroll(notification) }

    private func observeOpenStage(_ name: String) {
        openStageObserver?(name, DispatchTime.now().uptimeNanoseconds)
    }

}
#endif
