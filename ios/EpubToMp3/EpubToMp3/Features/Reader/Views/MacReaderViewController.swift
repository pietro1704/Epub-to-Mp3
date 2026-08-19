#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit
import Combine

@MainActor
final class MacReaderViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let bookmarkStore: BookmarkStore
    private let onClose: () -> Void
    private let chaptersTable = NSTableView()
    private let textView = MacReaderTextView()
    private let comicPageImageView = NSImageView()
    private let contentScrollView = NSScrollView()
    private let toolbar = NSStackView()
    private let bookTitleLabel = NSTextField(labelWithString: "")
    private let chapterTitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let loadingOverlay = NSVisualEffectView()
    private let loadingCoverView = NSImageView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingTitleLabel = NSTextField(labelWithString: "")
    private let loadingStatusLabel = NSTextField(labelWithString: "")
    private let loadingRetryButton = NSButton()
    private let tocPopover = NSPopover()
    private let settingsPopover = NSPopover()
    private var settingsCancellables: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = UUID()
    private var activeBookOpenJourneyID: UUID?
    private var pendingPDFPageJourneyID: UUID?
    private var firstPDFPageReadyJourneyID: UUID?
    private var controlsReadyJourneyID: UUID?
    private var pdfView: PDFView?
    private var fulltext: EbookFulltext?
    private var selectedChapter = 0
    private var currentBookId: String?
    /// Guards against re-seeking scroll position on every manual chapter
    /// selection — restoration only makes sense once per book load.
    private var hasRestoredInitialPosition = false

    init(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        bookmarkStore: BookmarkStore,
        onClose: @escaping () -> Void
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.bookmarkStore = bookmarkStore
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        loadTask?.cancel()
        if let journeyID = activeBookOpenJourneyID {
            _ = LatencyObservationStore.shared.cancel(journeyID)
        }
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
        view = surface
        view.wantsLayer = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        persistReadingProgress()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureReader()
        settings.objectWillChange
            .sink { [weak self] _ in
                guard let self, self.fulltext != nil else { return }
                self.showChapter(self.selectedChapter)
            }
            .store(in: &settingsCancellables)
        loadCurrentBook()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScrollDidEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: contentScrollView
        )
    }

    func setBook(_ bookID: String?) {
        UserDefaults.standard.set(bookID, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        loadCurrentBook()
    }

    private var tocRows: [ReaderTocRow] {
        guard let fulltext else { return [] }
        return ReaderTocFlattener.rows(toc: fulltext.toc, chapters: fulltext.chapters)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tocRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("MacChapterCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let textField = NSTextField(labelWithString: "")
            textField.lineBreakMode = .byTruncatingTail
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let tocRow = tocRows[safe: row]
        cell.textField?.stringValue = tocRow.map { String(repeating: "    ", count: $0.level) + $0.title } ?? ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = chaptersTable.selectedRow
        guard row >= 0, let chapterIndex = tocRows[safe: row]?.chapterIndex else { return }
        persistReadingProgress()
        selectedChapter = chapterIndex
        showChapter(chapterIndex)
        tocPopover.performClose(nil)
    }

    private func configureReader() {
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.string("reader.close")) ?? NSImage(), target: self, action: #selector(closeReader))
        close.bezelStyle = .texturedRounded
        close.toolTip = L10n.string("reader.close")
        close.setAccessibilityIdentifier("reader.close")

        let toc = NSButton(title: L10n.string("reader.toc"), target: self, action: #selector(showTOC(_:)))
        toc.bezelStyle = .texturedRounded
        toc.toolTip = L10n.string("reader.toc")
        toc.setAccessibilityIdentifier("reader.toc")

        let search = NSButton(
            image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L10n.string("reader.search.placeholder")) ?? NSImage(),
            target: self, action: #selector(promptSearch)
        )
        search.bezelStyle = .texturedRounded
        search.toolTip = L10n.string("reader.search.placeholder")
        search.setAccessibilityIdentifier("reader.search")

        let appearance = NSButton(title: "Aa", target: self, action: #selector(showSettings(_:)))
        appearance.bezelStyle = .texturedRounded
        appearance.toolTip = L10n.string("reader.settings")
        appearance.setAccessibilityLabel(L10n.string("reader.settings"))
        appearance.setAccessibilityIdentifier("reader.settings")

        bookTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bookTitleLabel.alignment = .center
        bookTitleLabel.lineBreakMode = .byTruncatingTail
        bookTitleLabel.setAccessibilityIdentifier("reader.title")
        bookTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let leadingControls = NSStackView(views: [close, toc, search, appearance])
        leadingControls.orientation = .horizontal
        leadingControls.spacing = 8
        let leadingSpacer = NSView()
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let trailingSpacer = NSView()
        trailingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(leadingControls)
        toolbar.addArrangedSubview(leadingSpacer)
        toolbar.addArrangedSubview(bookTitleLabel)
        toolbar.addArrangedSubview(trailingSpacer)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        toolbar.setAccessibilityIdentifier("reader.toolbar")

        chapterTitleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        chapterTitleLabel.lineBreakMode = .byTruncatingTail
        chapterTitleLabel.setAccessibilityIdentifier("reader.chapterTitle")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.setAccessibilityIdentifier("reader.status")
        textView.isEditable = false
        textView.isSelectable = true
        textView.onLinkClick = { [weak self] url, linkText in
            self?.handleReaderLink(url, linkText: linkText) ?? true
        }
        textView.setAccessibilityIdentifier("reader.content")
        textView.font = .systemFont(ofSize: settings.readerPointSize)
        textView.textContainerInset = NSSize(width: 32, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        contentScrollView.documentView = textView
        contentScrollView.hasVerticalScroller = true
        contentScrollView.drawsBackground = false

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        chapterTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        view.addSubview(chapterTitleLabel)
        view.addSubview(statusLabel)
        view.addSubview(contentScrollView)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            chapterTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 34),
            chapterTitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -34),
            chapterTitleLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: chapterTitleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: chapterTitleLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: chapterTitleLabel.bottomAnchor, constant: 8),
            contentScrollView.leadingAnchor.constraint(equalTo: chapterTitleLabel.leadingAnchor),
            contentScrollView.trailingAnchor.constraint(equalTo: chapterTitleLabel.trailingAnchor),
            contentScrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            contentScrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -22),
        ])
        configureLoadingOverlay()
        textView.onKeyDown = { [weak self] event in
            self?.handleKeyboardEvent(event) ?? false
        }
        textView.onPageTap = { [weak self] forward in
            self?.scrollPage(forward: forward)
            return true
        }
        textView.onBuildSelectionMenu = { [weak self] range in
            self?.buildSelectionMenuItems(range: range) ?? []
        }
    }

    private func configureLoadingOverlay() {
        loadingOverlay.material = .contentBackground
        loadingOverlay.blendingMode = .withinWindow
        loadingOverlay.state = .active
        loadingOverlay.isHidden = true
        loadingOverlay.setAccessibilityIdentifier("reader.loadingOverlay")
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false

        loadingCoverView.imageScaling = .scaleProportionallyUpOrDown
        loadingCoverView.wantsLayer = true
        loadingCoverView.layer?.cornerRadius = 12
        loadingCoverView.layer?.masksToBounds = true
        loadingCoverView.translatesAutoresizingMaskIntoConstraints = false

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.isIndeterminate = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false

        loadingTitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        loadingTitleLabel.alignment = .center
        loadingTitleLabel.lineBreakMode = .byTruncatingTail
        loadingStatusLabel.textColor = .secondaryLabelColor
        loadingStatusLabel.alignment = .center
        loadingStatusLabel.setAccessibilityIdentifier("reader.loadingStatus")
        loadingRetryButton.title = L10n.string("reader.retry")
        loadingRetryButton.bezelStyle = .rounded
        loadingRetryButton.target = self
        loadingRetryButton.action = #selector(retryLoadingBook)
        loadingRetryButton.isHidden = true

        let stack = NSStackView(views: [
            loadingCoverView,
            loadingSpinner,
            loadingTitleLabel,
            loadingStatusLabel,
            loadingRetryButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(stack)
        view.addSubview(loadingOverlay)

        let preferredCoverWidth = loadingCoverView.widthAnchor.constraint(
            equalTo: loadingOverlay.widthAnchor,
            multiplier: 0.28
        )
        preferredCoverWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: loadingOverlay.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: loadingOverlay.trailingAnchor, constant: -32),
            preferredCoverWidth,
            loadingCoverView.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            loadingCoverView.heightAnchor.constraint(equalTo: loadingCoverView.widthAnchor, multiplier: 1.5),
            loadingCoverView.heightAnchor.constraint(lessThanOrEqualTo: loadingOverlay.heightAnchor, multiplier: 0.45),
        ])
        // The reader toolbar remains available for closing the book while
        // parsing continues underneath the loading surface.
        view.addSubview(toolbar, positioned: .above, relativeTo: loadingOverlay)
    }

    private func showLoading(for book: BookEntity) {
        loadingCoverView.image = book.coverPNG.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil)
        loadingTitleLabel.stringValue = book.resolvedTitle
        loadingStatusLabel.stringValue = L10n.string("reader.loading")
        loadingRetryButton.isHidden = true
        loadingOverlay.isHidden = false
        loadingSpinner.startAnimation(nil)
    }

    private func showLoadingError(_ error: Error) {
        cancelActiveBookOpenJourney()
        loadingStatusLabel.stringValue = error.localizedDescription
        loadingRetryButton.isHidden = false
        loadingOverlay.isHidden = false
        loadingSpinner.stopAnimation(nil)
    }

    private func hideLoading() {
        loadingSpinner.stopAnimation(nil)
        loadingOverlay.isHidden = true
    }

    private func isActiveLoad(_ generation: UUID, bookID: String) -> Bool {
        !Task.isCancelled && loadGeneration == generation && currentBookId == bookID
    }

    private func configureTOCPopover() {
        chaptersTable.headerView = nil
        chaptersTable.delegate = self
        chaptersTable.dataSource = self
        chaptersTable.usesAlternatingRowBackgroundColors = true
        chaptersTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chapter")))
        let scrollView = NSScrollView()
        scrollView.documentView = chaptersTable
        scrollView.hasVerticalScroller = true
        let controller = NSViewController()
        controller.view = scrollView
        tocPopover.contentViewController = controller
        tocPopover.contentSize = NSSize(width: 320, height: 480)
        tocPopover.behavior = .transient
    }

    private func configureSettingsPopover() {
        let font = NSPopUpButton()
        font.addItems(withTitles: ReaderFontFamily.allCases.map(\.displayName))
        font.selectItem(at: ReaderFontFamily.allCases.firstIndex(of: settings.readerFontFamily) ?? 0)
        font.target = self
        font.action = #selector(fontChanged(_:))

        let theme = NSPopUpButton()
        theme.addItems(withTitles: ReaderTheme.allCases.map(\.displayName))
        theme.selectItem(at: ReaderTheme.allCases.firstIndex(of: settings.readerTheme) ?? 0)
        theme.target = self
        theme.action = #selector(themeChanged(_:))

        let layout = NSPopUpButton()
        layout.addItems(withTitles: ReaderLayout.allCases.map(\.displayName))
        layout.selectItem(at: ReaderLayout.allCases.firstIndex(of: settings.readerLayout) ?? 0)
        layout.target = self
        layout.action = #selector(layoutChanged(_:))

        let smaller = NSButton(title: "A−", target: self, action: #selector(decreaseFont))
        let larger = NSButton(title: "A+", target: self, action: #selector(increaseFont))
        let sizeButtons = NSStackView(views: [smaller, larger])
        sizeButtons.spacing = 8
        let margin = NSPopUpButton()
        margin.addItems(withTitles: ["16", "24", "32", "48", "64"])
        margin.selectItem(withTitle: String(Int(settings.readerMargin)))
        margin.target = self
        margin.action = #selector(marginChanged(_:))

        let kerning = NSPopUpButton()
        kerning.addItems(withTitles: ["-1", "0", "0.5", "1", "2", "3"])
        kerning.selectItem(withTitle: String(settings.readerLetterSpacing))
        kerning.target = self
        kerning.action = #selector(kerningChanged(_:))

        let columns = NSPopUpButton()
        columns.addItems(withTitles: ["1", "2", "3", "4"])
        columns.selectItem(withTitle: String(settings.readerColumns))
        columns.target = self
        columns.action = #selector(columnsChanged(_:))

        let stack = NSStackView(views: [label("reader.font"), font, sizeButtons, label("reader.theme"), theme, label("reader.layout"), layout, label("reader.margins"), margin, label("reader.kerning"), kerning, label("reader.columns"), columns])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = stack
        scrollView.drawsBackground = false
        let controller = NSViewController()
        controller.view = scrollView
        settingsPopover.contentViewController = controller
        settingsPopover.contentSize = NSSize(width: 260, height: 420)
        settingsPopover.behavior = .transient
    }

    private func label(_ key: String) -> NSTextField {
        let field = NSTextField(labelWithString: L10n.string(key))
        field.setAccessibilityRole(.staticText)
        return field
    }

    @objc private func showSettings(_ sender: NSButton) {
        if settingsPopover.contentViewController == nil { configureSettingsPopover() }
        settingsPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        settings.readerFontFamily = ReaderFontFamily.allCases[sender.indexOfSelectedItem]
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        settings.readerTheme = ReaderTheme.allCases[sender.indexOfSelectedItem]
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        settings.readerLayout = ReaderLayout.allCases[sender.indexOfSelectedItem]
    }

    @objc private func marginChanged(_ sender: NSPopUpButton) {
        settings.readerMargin = Double(sender.titleOfSelectedItem ?? "24") ?? 24
    }

    @objc private func kerningChanged(_ sender: NSPopUpButton) {
        settings.readerLetterSpacing = Double(sender.titleOfSelectedItem ?? "0") ?? 0
    }

    @objc private func columnsChanged(_ sender: NSPopUpButton) {
        settings.readerColumns = Int(sender.titleOfSelectedItem ?? "1") ?? 1
    }

    @objc private func decreaseFont() { settings.readerFontSize -= 1 }
    @objc private func increaseFont() { settings.readerFontSize += 1 }

    private func loadCurrentBook() {
        guard isViewLoaded else { return }
        loadTask?.cancel()
        cancelActiveBookOpenJourney()
        let generation = UUID()
        loadGeneration = generation
        contentScrollView.documentView = textView
        let id = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        guard let book = library.books.first(where: { $0.id == id }) else {
            fulltext = nil
            currentBookId = nil
            bookTitleLabel.stringValue = L10n.string("library.empty.title")
            chapterTitleLabel.stringValue = ""
            statusLabel.stringValue = L10n.string("reader.selectBook")
            textView.string = ""
            chaptersTable.reloadData()
            hideLoading()
            return
        }
        if currentBookId != book.id {
            currentBookId = book.id
            hasRestoredInitialPosition = false
        }
        let journeyID = LatencyObservationStore.shared.beginBookOpen(
            documentKind: Self.documentKind(for: book)
        )
        activeBookOpenJourneyID = journeyID
        // Process-warm reader opens must not clear the visible chapter or
        // show the loading cover. The last two prepared books are retained
        // in memory precisely so this route can paint immediately.
        if let warmPayload = LocalFulltextCache.inMemoryPayload(bookId: book.id),
           !warmPayload.chapters.isEmpty {
            LatencyObservationStore.shared.classifyCache(.inMemoryWarm, for: journeyID)
            fulltext = warmPayload
            LocalFulltextCache.recordWarmOpen(bookId: book.id)
            bookTitleLabel.stringValue = book.resolvedTitle
            chapterTitleLabel.stringValue = ""
            statusLabel.stringValue = L10n.string("reader.chapterCount", warmPayload.chapters.count)
            chaptersTable.reloadData()
            if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
                selectedChapter = entry.chapterIndex
            }
            selectedChapter = min(max(selectedChapter, 0), max(0, warmPayload.chapters.count - 1))
            if let row = tocRows.firstIndex(where: { $0.chapterIndex == selectedChapter }) {
                chaptersTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            showChapter(selectedChapter)
            restoreReadingProgressIfNeeded(bookId: book.id)
            recordReadableContent()
            hideLoading()
            recordControlsUsable()
            return
        }
        fulltext = nil
        textView.string = ""
        comicPageImageView.image = nil
        chaptersTable.reloadData()
        bookTitleLabel.stringValue = book.resolvedTitle
        chapterTitleLabel.stringValue = ""
        statusLabel.stringValue = L10n.string("reader.loading")
        showLoading(for: book)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cachedPayload = await Task.detached(priority: .userInitiated) {
                    LocalFulltextCache.read(bookId: book.id)
                }.value
                let payload: EbookFulltext
                if let cachedPayload {
                    LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
                    payload = cachedPayload
                } else {
                    LatencyObservationStore.shared.classifyCache(.cold, for: journeyID)
                    let fileURL = try await library.openBookFileAsync(id: book.id)
                    guard self.isActiveLoad(generation, bookID: book.id) else { return }
                    if book.fileType == .pdf {
                        pendingPDFPageJourneyID = journeyID
                        guard let wasNormalized = await showPDF(fileURL) else { return }
                        guard self.isActiveLoad(generation, bookID: book.id) else { return }
                        recordFirstPDFPage(wasNormalized: wasNormalized)
                        self.hideLoading()
                        recordControlsUsable()
                        return
                    }
                    if book.fileType.requiresServerConversion {
                        guard let baseURL = settings.resolvedBaseURL else {
                            throw APIError.invalidBaseURL
                        }
                        let client = APIClient(baseURL: baseURL)
                        let uploadID = try await client.uploadBook(at: fileURL)
                        payload = try await client.fetchUploadedFulltext(uploadID: uploadID)
                    } else {
                        payload = try await MacEpubParser.parse(at: fileURL, bookId: book.id)
                    }
                }
                guard self.isActiveLoad(generation, bookID: book.id) else { return }
                LocalFulltextCache.save(payload, bookId: book.id)
                LocalFulltextCache.recordWarmOpen(bookId: book.id)
                fulltext = payload
                statusLabel.stringValue = L10n.string("reader.chapterCount", payload.chapters.count)
                chaptersTable.reloadData()
                if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
                    selectedChapter = entry.chapterIndex
                } else {
                    let firstReadableChapter = payload.chapters.firstIndex {
                        $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80
                    } ?? 0
                    selectedChapter = min(max(selectedChapter, firstReadableChapter), max(0, payload.chapters.count - 1))
                }
                selectedChapter = min(max(selectedChapter, 0), max(0, payload.chapters.count - 1))
                if let row = self.tocRows.firstIndex(where: { $0.chapterIndex == self.selectedChapter }) {
                    chaptersTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                showChapter(selectedChapter)
                restoreReadingProgressIfNeeded(bookId: book.id)
                recordReadableContent()
                hideLoading()
                recordControlsUsable()
            } catch {
                guard self.isActiveLoad(generation, bookID: book.id) else { return }
                statusLabel.stringValue = error.localizedDescription
                textView.string = ""
                showLoadingError(error)
            }
        }
    }

    @objc private func retryLoadingBook() {
        loadCurrentBook()
    }

    private func showChapter(_ index: Int, scrollToEnd: Bool = false) {
        guard let chapter = fulltext?.chapters[safe: index] else { return }
        chapterTitleLabel.stringValue = chapter.name ?? ""

        if chapter.isImageOnly {
            if let base64 = chapter.resources?.first?.dataBase64, let data = Data(base64Encoded: base64) {
                comicPageImageView.image = NSImage(data: data)
            } else {
                comicPageImageView.image = nil
            }
            comicPageImageView.imageScaling = .scaleProportionallyUpOrDown
            contentScrollView.documentView = comicPageImageView
        } else {
            contentScrollView.documentView = textView
            if let html = chapter.html,
               let rendered = EpubHtmlRenderer.render(
                   html: html, css: chapter.css, settings: settings, resources: chapter.resources
               ) {
                textView.textStorage?.setAttributedString(NSAttributedString(rendered))
            } else {
                textView.string = chapter.text
                textView.font = .systemFont(ofSize: settings.readerPointSize)
            }
            repaintSavedHighlights(chapterIndex: index)
            if scrollToEnd {
                DispatchQueue.main.async { [weak self] in
                    self?.textView.scrollToEndOfDocument(nil)
                }
            } else {
                textView.scrollToBeginningOfDocument(nil)
            }
        }
        UserDefaults.standard.set(index, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
    }

    private func handleReaderLink(_ url: URL, linkText: String) -> Bool {
        guard let fulltext, let chapter = fulltext.chapters[safe: selectedChapter] else {
            return true
        }
        switch ReaderLinkResolver.destination(
            for: url,
            linkText: linkText,
            currentChapter: chapter,
            chapters: fulltext.chapters
        ) {
        case .chapter(let index):
            guard fulltext.chapters.indices.contains(index) else { return true }
            persistReadingProgress()
            selectedChapter = index
            showChapter(index)
            return true
        case .footnote(let footnote):
            showFootnote(footnote)
            return true
        case .external:
            return false
        case .unresolved:
            return true
        }
    }

    // MARK: - Selection → bookmark/highlight/note

    private struct PendingSelection {
        let range: NSRange
        let text: String
    }

    /// Repaints every saved highlight for this chapter as a background
    /// tint, resolved against the text actually on screen right now
    /// (`ReaderTextHighlight`), not the Python `chapter.text` pipeline.
    private func repaintSavedHighlights(chapterIndex: Int) {
        guard let bookId = currentBookId else { return }
        let highlights = bookmarkStore.bookmarks(for: bookId, chapterIndex: chapterIndex).filter { $0.isHighlight }
        guard !highlights.isEmpty, let storage = textView.textStorage, storage.length > 0 else { return }
        for bookmark in highlights {
            let span = SentenceSpan(
                id: bookmark.id.uuidString, text: bookmark.selectedText,
                startChar: bookmark.startChar, endChar: bookmark.endChar
            )
            guard let range = ReaderTextHighlight.range(for: span, in: storage) else { continue }
            storage.addAttribute(.backgroundColor, value: bookmark.color.platformColor, range: range)
        }
    }

    private func buildSelectionMenuItems(range: NSRange) -> [NSMenuItem] {
        let full = textView.string as NSString
        guard range.location + range.length <= full.length else { return [] }
        let selectedText = full.substring(with: range)
        let payload = PendingSelection(range: range, text: selectedText)

        let highlight = NSMenuItem(
            title: L10n.string("reader.action.highlight"),
            action: #selector(highlightSelectionFromMenu(_:)), keyEquivalent: ""
        )
        highlight.target = self
        highlight.representedObject = payload

        let note = NSMenuItem(
            title: L10n.string("reader.action.addNote"),
            action: #selector(addNoteForSelectionFromMenu(_:)), keyEquivalent: ""
        )
        note.target = self
        note.representedObject = payload

        return [highlight, note]
    }

    @objc private func highlightSelectionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? PendingSelection else { return }
        addBookmark(range: payload.range, selectedText: payload.text, note: nil)
    }

    @objc private func addNoteForSelectionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? PendingSelection else { return }
        promptForNote(range: payload.range, selectedText: payload.text)
    }

    private func promptForNote(range: NSRange, selectedText: String) {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.action.addNote")
        alert.informativeText = selectedText
        alert.addButton(withTitle: L10n.string("common.save"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L10n.string("reader.note.placeholder")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addBookmark(range: range, selectedText: selectedText, note: field.stringValue)
    }

    private func addBookmark(range: NSRange, selectedText: String, note: String?) {
        guard let bookId = currentBookId else { return }
        bookmarkStore.addBookmark(
            bookId: bookId,
            chapterIndex: selectedChapter,
            chapterTitle: fulltext?.chapters[safe: selectedChapter]?.name ?? "",
            startChar: range.location,
            endChar: range.location + range.length,
            selectedText: selectedText,
            note: note,
            color: .yellow
        )
        repaintSavedHighlights(chapterIndex: selectedChapter)
    }

    @objc private func closeReader() { onClose() }

    private func handleKeyboardEvent(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 124, 125, 49:
            scrollPage(forward: true)
            return true
        case 123, 126:
            scrollPage(forward: false)
            return true
        case 53:
            closeReader()
            return true
        default:
            return false
        }
    }

    private func scrollPage(forward: Bool) {
        guard let documentView = contentScrollView.documentView else { return }
        contentScrollView.layoutSubtreeIfNeeded()
        let clipView = contentScrollView.contentView
        let visibleBounds = clipView.bounds
        let page = max(1, visibleBounds.height * 0.9)
        let maximumY = max(0, documentView.frame.height - visibleBounds.height)
        let atStart = visibleBounds.origin.y <= 1
        let atEnd = visibleBounds.origin.y >= maximumY - 1
        if forward && atEnd, selectedChapter + 1 < (fulltext?.chapters.count ?? 0) {
            persistReadingProgress()
            selectedChapter += 1
            showChapter(selectedChapter)
            selectCurrentTOCRow()
            return
        }
        if !forward && atStart, selectedChapter > 0 {
            persistReadingProgress()
            selectedChapter -= 1
            showChapter(selectedChapter, scrollToEnd: true)
            selectCurrentTOCRow()
            return
        }
        let offset = forward ? page : -page
        let nextY = min(max(visibleBounds.origin.y + offset, 0), maximumY)
        clipView.scroll(to: NSPoint(x: visibleBounds.origin.x, y: nextY))
        contentScrollView.reflectScrolledClipView(clipView)
        persistReadingProgress()
    }

    private func selectCurrentTOCRow() {
        guard let row = tocRows.firstIndex(where: { $0.chapterIndex == selectedChapter }) else { return }
        chaptersTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - Pagination (viewport snap) + progress restoration

    /// In `.paginated` mode, after a trackpad/scroll-wheel gesture ends,
    /// rounds the scroll position to the nearest multiple of the viewport
    /// height so it lands on a "page" boundary. `.scrolling` mode is
    /// untouched (free continuous scroll).
    @objc private func handleScrollDidEndLiveScroll(_ notification: Notification) {
        guard settings.readerLayout == .paginated,
              let documentView = contentScrollView.documentView else { return }
        let clipView = contentScrollView.contentView
        let pageHeight = clipView.bounds.height
        guard pageHeight > 0 else { return }
        let page = (clipView.bounds.origin.y / pageHeight).rounded()
        let maxY = max(0, documentView.frame.height - pageHeight)
        let snappedY = min(max(page * pageHeight, 0), maxY)
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: snappedY))
        contentScrollView.reflectScrolledClipView(clipView)
        persistReadingProgress()
    }

    private func persistReadingProgress() {
        guard let bookId = currentBookId, let documentView = contentScrollView.documentView else { return }
        let clipView = contentScrollView.contentView
        let scrollable = max(documentView.frame.height - clipView.bounds.height, 1)
        let fraction = clipView.bounds.origin.y / scrollable
        ReaderProgressStore.save(bookId: bookId, chapterIndex: selectedChapter, offsetFraction: fraction)
    }

    /// Called once, right after a fresh `loadCurrentBook()`, to jump back to
    /// the exact chapter + scroll fraction the user left off at. Runs on the
    /// next runloop tick so the scroll view has already been laid out.
    private func restoreReadingProgressIfNeeded(bookId: String) {
        guard !hasRestoredInitialPosition else { return }
        hasRestoredInitialPosition = true
        guard let entry = ReaderProgressStore.read(bookId: bookId) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let documentView = self.contentScrollView.documentView else { return }
            let clipView = self.contentScrollView.contentView
            let scrollable = max(documentView.frame.height - clipView.bounds.height, 0)
            guard scrollable > 0 else { return }
            clipView.scroll(to: NSPoint(x: 0, y: entry.offsetFraction * scrollable))
            self.contentScrollView.reflectScrolledClipView(clipView)
        }
    }

    @objc private func showTOC(_ sender: NSButton) {
        if tocPopover.contentViewController == nil { configureTOCPopover() }
        tocPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: - Footnotes

    /// Native alert listing `{number, text}` pairs for the current
    /// chapter — no attempt to resolve a tap-to-jump from an inline
    /// reference (see the iOS `FootnotesSheetController` doc comment for
    /// why that's fragile).
    @objc private func showFootnotes() {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.footnotes.title")
        let footnotes = fulltext?.chapters[safe: selectedChapter]?.footnotes ?? []
        if footnotes.isEmpty {
            alert.informativeText = L10n.string("reader.footnotes.empty")
        } else {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = false
            textView.string = footnotes.enumerated()
                .map { "\($1.number ?? String($0 + 1)). \($1.text)" }
                .joined(separator: "\n\n")
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            alert.accessoryView = scrollView
        }
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

    private func showFootnote(_ footnote: EbookFulltext.Footnote) {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.footnotes.title")
        let numberPrefix = footnote.number.map { "\($0)\n\n" } ?? ""
        alert.informativeText = numberPrefix + footnote.text
        alert.addButton(withTitle: L10n.string("common.ok"))
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - In-chapter search

    @objc private func promptSearch() {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.search.placeholder")
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        performSearch(query: field.stringValue)
    }

    private func performSearch(query: String) {
        guard let chapters = fulltext?.chapters, !chapters.isEmpty else { return }
        let order = Array(chapters.indices.dropFirst(selectedChapter))
            + Array(chapters.indices.prefix(selectedChapter + 1))
        for chapterIndex in order {
            let full = chapters[chapterIndex].text as NSString
            let range = full.range(of: query, options: .caseInsensitive)
            guard range.location != NSNotFound else { continue }
            if chapterIndex != selectedChapter {
                persistReadingProgress()
                selectedChapter = chapterIndex
                showChapter(chapterIndex)
            }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.search.noResults")
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

    private static func documentKind(for book: BookEntity) -> LatencyObservation.DocumentKind {
        book.fileType == .pdf ? .selectableTextPDF : .epub
    }

    private func recordReadableContent() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
    }

    private func recordFirstPDFPage(wasNormalized: Bool) {
        guard let journeyID = pendingPDFPageJourneyID,
              journeyID == activeBookOpenJourneyID
        else {
            return
        }
        if wasNormalized {
            LatencyObservationStore.shared.classifyDocument(.normalizedScannedPDF, for: journeyID)
        }
        _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
        _ = LatencyObservationStore.shared.record(.firstPDFPage, for: journeyID)
        firstPDFPageReadyJourneyID = journeyID
        finishPDFJourneyIfReady(journeyID)
    }

    private func recordControlsUsable() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.record(.controlsUsable, for: journeyID)
        if pendingPDFPageJourneyID == journeyID {
            controlsReadyJourneyID = journeyID
            finishPDFJourneyIfReady(journeyID)
        } else {
            LatencyObservationStore.shared.finish(journeyID)
            activeBookOpenJourneyID = nil
        }
    }

    private func finishPDFJourneyIfReady(_ journeyID: UUID) {
        guard firstPDFPageReadyJourneyID == journeyID,
              controlsReadyJourneyID == journeyID
        else {
            return
        }
        LatencyObservationStore.shared.finish(journeyID)
        activeBookOpenJourneyID = nil
        pendingPDFPageJourneyID = nil
        firstPDFPageReadyJourneyID = nil
        controlsReadyJourneyID = nil
    }

    private func cancelActiveBookOpenJourney() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.cancel(journeyID)
        activeBookOpenJourneyID = nil
        pendingPDFPageJourneyID = nil
        firstPDFPageReadyJourneyID = nil
        controlsReadyJourneyID = nil
    }

    private func showPDF(_ url: URL) async -> Bool? {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        pdfView = view
        statusLabel.stringValue = L10n.string("reader.pdf")
        chapterTitleLabel.stringValue = ""
        contentScrollView.documentView = view
        let normalized = await Task.detached(priority: .userInitiated) {
            PdfReadingPageNormalizer.normalizedDocument(from: url)
        }.value
        guard pdfView === view else { return nil }
        view.document = normalized ?? PDFDocument(url: url)
        return normalized != nil
    }
}

private final class MacReaderSurfaceView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onPageTap: ((Bool) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard onKeyDown?(event) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let forward = location.x >= bounds.midX
        if onPageTap?(forward) != true { super.mouseUp(with: event) }
    }
}

final class MacReaderTextView: NSTextView, NSTextViewDelegate {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onPageTap: ((Bool) -> Bool)?
    var onBuildSelectionMenu: ((NSRange) -> [NSMenuItem])?
    var onLinkClick: ((URL, String) -> Bool)?

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func keyDown(with event: NSEvent) {
        guard onKeyDown?(event) == true else {
            super.keyDown(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let characterIndex = characterIndex(at: location), shouldDeferMouseUpToTextSystem(at: characterIndex) {
            super.mouseUp(with: event)
            return
        }
        let forward = location.x >= bounds.midX
        if onPageTap?(forward) != true { super.mouseUp(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event)
        let selection = selectedRange()
        guard selection.length > 0, let extra = onBuildSelectionMenu?(selection), !extra.isEmpty else {
            return base
        }
        let menu = base ?? NSMenu()
        for (offset, item) in extra.enumerated() {
            menu.insertItem(item, at: offset)
        }
        menu.insertItem(.separator(), at: extra.count)
        return menu
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = Self.url(from: link),
              charIndex != NSNotFound,
              charIndex >= 0,
              charIndex < string.utf16.count else {
            return false
        }
        var linkRange = NSRange(location: charIndex, length: 0)
        textStorage?.attribute(.link, at: charIndex, effectiveRange: &linkRange)
        let linkText = (string as NSString).substring(with: linkRange)
        return onLinkClick?(url, linkText) ?? false
    }

    func shouldDeferMouseUpToTextSystem(at characterIndex: Int) -> Bool {
        guard characterIndex != NSNotFound,
              characterIndex >= 0,
              characterIndex < string.utf16.count else {
            return false
        }
        return textStorage?.attribute(.link, at: characterIndex, effectiveRange: nil) != nil
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let textContainerPoint = NSPoint(
            x: point.x - textContainerOrigin.x,
            y: point.y - textContainerOrigin.y
        )
        let index = layoutManager.characterIndex(
            for: textContainerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return index == NSNotFound ? nil : index
    }

    private static func url(from link: Any) -> URL? {
        if let url = link as? URL { return url }
        if let url = link as? NSURL { return url as URL }
        if let value = link as? String { return URL(string: value) }
        return nil
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
