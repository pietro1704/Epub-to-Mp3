#if os(macOS)
import AppKit
import PDFKit

@MainActor
final class MacReaderContentsPresentation: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let document: MacReaderDocument
    private let composition: MacReaderViewComposition
    private let persistProgress: () -> Void
    private let showChapter: (Int) -> Void
    private var isSynchronizingTOCSelection = false
    /// Chapter audio of the open book; `nil` when the book cannot be narrated.
    private let makeDownloads: () -> ReaderChapterDownloads?
    private var downloads: ReaderChapterDownloads?
    private var downloadedChapters: Set<Int> = []
    private var downloadRefreshTask: Task<Void, Never>?
    private var artifactObserver: NSObjectProtocol?
    private let actionsPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let downloadStatus = NSTextField(labelWithString: "")
    private var chaptersTable: NSTableView { composition.chaptersTable }
    private var tocPopover: NSPopover { composition.tocPopover }
    private var selectedChapter: Int {
        get { document.selectedChapter }
        set { document.selectedChapter = newValue }
    }
    private var fulltext: EbookFulltext? {
        get { document.fulltext }
        set { document.fulltext = newValue }
    }

    init(document: MacReaderDocument, composition: MacReaderViewComposition,
         persistProgress: @escaping () -> Void, showChapter: @escaping (Int) -> Void,
         makeDownloads: @escaping () -> ReaderChapterDownloads? = { nil }) {
        self.makeDownloads = makeDownloads
        self.document = document
        self.composition = composition
        self.persistProgress = persistProgress
        self.showChapter = showChapter
        super.init()
    }

    deinit {
        downloadRefreshTask?.cancel()
        if let artifactObserver { NotificationCenter.default.removeObserver(artifactObserver) }
    }

    private var tocRows: [ReaderTocRow] { document.tocRows }

    func numberOfRows(in tableView: NSTableView) -> Int { tocRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("MacChapterCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? MacChapterCellView) ?? MacChapterCellView()
        cell.identifier = identifier
        let tocRow = tocRows[safe: row]
        cell.textField?.stringValue = tocRow.map { String(repeating: "    ", count: $0.level) + $0.title } ?? ""
        // Spoken name is the chapter title; the indentation is conveyed by the row's disclosure level.
        let spoken = tocRow.map { $0.title.isEmpty ? L10n.string("toc.untitledChapter") : $0.title }
        cell.textField?.setAccessibilityLabel(spoken)
        cell.setAccessibilityLabel(spoken)
        configureAudio(cell, chapter: downloads == nil ? nil : sourceIndex(of: tocRow))
        return cell
    }

    private func sourceIndex(of row: ReaderTocRow?) -> Int? {
        guard let chapters = fulltext?.chapters else { return nil }
        return row?.chapterIndex.flatMap { ReaderPlaybackAnchor.epubIndex(forReaderPosition: $0, in: chapters) }
    }

    private func configureAudio(_ cell: MacChapterCellView, chapter: Int?) {
        let button = cell.downloadButton
        guard let chapter else {
            button.isHidden = true
            cell.stateLabel.stringValue = ""
            return
        }
        let isDownloaded = downloadedChapters.contains(chapter)
        let label = L10n.string(isDownloaded ? "toc.removeDownload" : "player.downloadChapter")
        button.isHidden = false
        button.image = NSImage(systemSymbolName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle",
                               accessibilityDescription: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier("reader.toc.download.\(chapter)")
        button.tag = chapter
        button.target = self
        button.action = #selector(toggleChapterDownload(_:))
        cell.stateLabel.stringValue = isDownloaded ? L10n.string("toc.downloaded") : ""
    }

    @objc private func toggleChapterDownload(_ sender: NSButton) {
        let chapter = sender.tag
        guard let downloads else { return }
        guard downloadedChapters.contains(chapter) else {
            downloads.start([chapter])
            refreshActions()
            return
        }
        let title = tocRows.first { sourceIndex(of: $0) == chapter }?.title ?? ""
        confirmRemoval(title: L10n.string("toc.removeDownload"),
                       message: L10n.string("toc.removeDownloadMessage", title)) {
            Task { await downloads.remove(chapter: chapter) }
        }
    }

    @objc private func downloadAllChapters() {
        downloads?.start(tocRows.compactMap { sourceIndex(of: $0) })
        refreshActions()
    }

    @objc private func cancelDownloads() { downloads?.cancel() }

    @objc private func removeAllDownloads() {
        guard let downloads else { return }
        confirmRemoval(title: L10n.string("chapterList.removeDownloads"),
                       message: L10n.string("chapterList.removeDownloadsMessage")) {
            Task { await downloads.remove(chapter: nil) }
        }
    }

    private func confirmRemoval(title: String, message: String, action: @escaping () -> Void) {
        // The transient popover closes behind a sheet, so the question belongs to the reader window.
        let window = composition.view.window
        tocPopover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("common.remove")).hasDestructiveAction = true
        alert.addButton(withTitle: L10n.string("common.cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }

    private func present(failure title: String, message: String) {
        guard let window = composition.view.window else { return }
        tocPopover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("player.close"))
        alert.beginSheetModal(for: window)
    }

    /// One download owner per open book, so closing the list does not forget a running download.
    private func prepareDownloads() {
        let candidate = makeDownloads()
        if candidate?.bookID != downloads?.bookID {
            downloads?.cancel()
            downloads = candidate
            downloadedChapters = []
            candidate?.onBusyChange = { [weak self] busy in
                self?.refreshActions()
                if !busy { self?.refreshDownloaded() }
            }
            candidate?.onError = { [weak self] in self?.present(failure: $0, message: $1) }
        }
        if artifactObserver == nil {
            artifactObserver = NotificationCenter.default.addObserver(
                forName: LocalAudioArtifactStore.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDownloaded() }
            }
        }
        refreshActions()
        refreshDownloaded()
    }

    private func refreshDownloaded() {
        guard let bookID = downloads?.bookID else { return }
        downloadRefreshTask?.cancel()
        downloadRefreshTask = Task { [weak self] in
            let downloaded = (try? await LocalAudioArtifactStore.shared.listenerDownloadedChapterIndices(bookID: bookID)) ?? []
            guard !Task.isCancelled, let self, self.downloads?.bookID == bookID else { return }
            self.downloadedChapters = downloaded
            self.chaptersTable.reloadData()
            self.selectCurrentTOCRow()
        }
    }

    private func refreshActions() {
        let busy = downloads?.isBusy == true
        downloadStatus.stringValue = busy ? L10n.string("toc.audioPreparing") : ""
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A pull-down shows its first item as the button itself.
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: "ellipsis.circle",
                             accessibilityDescription: L10n.string("player.downloadAll"))
        menu.addItem(face)
        for (key, action, enabled) in [
            ("player.downloadAll", #selector(downloadAllChapters), !busy),
            ("chapterList.cancelDownloads", #selector(cancelDownloads), busy),
            ("chapterList.removeDownloads", #selector(removeAllDownloads), true),
        ] {
            let item = NSMenuItem(title: L10n.string(key), action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        actionsPopUp.menu = menu
        actionsPopUp.superview?.isHidden = downloads == nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.setAccessibilityDisclosureLevel(tocRows[safe: row]?.level ?? 0)
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSynchronizingTOCSelection else { return }
        let row = chaptersTable.selectedRow
        guard row >= 0, let chapterIndex = tocRows[safe: row]?.chapterIndex else { return }
        persistProgress()
        selectedChapter = chapterIndex
        showChapter(chapterIndex)
        tocPopover.performClose(nil)
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
        actionsPopUp.setAccessibilityIdentifier("reader.toc.actions")
        actionsPopUp.isBordered = false
        downloadStatus.textColor = .readableSecondaryLabel
        let header = NSStackView(views: [downloadStatus, NSView(), actionsPopUp])
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        let content = NSStackView(views: [header, scrollView])
        content.orientation = .vertical
        content.spacing = 0
        for view in [header, scrollView] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let controller = NSViewController()
        controller.view = content
        // A stack of scrollable content has no height of its own for the popover to adopt.
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 320),
            content.heightAnchor.constraint(equalToConstant: 480),
        ])
        tocPopover.contentViewController = controller
        tocPopover.contentSize = NSSize(width: 320, height: 480)
        tocPopover.behavior = .transient
    }

    func selectCurrentTOCRow() {
        guard let row = tocRows.firstIndex(where: { $0.chapterIndex == selectedChapter }) else { return }
        // Updating the TOC highlight is not a request to reopen the chapter.
        isSynchronizingTOCSelection = true
        defer { isSynchronizingTOCSelection = false }
        chaptersTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func showTOC(_ sender: NSButton) {
        guard fulltext != nil else { return }
        if tocPopover.contentViewController == nil { configureTOCPopover() }
        prepareDownloads()
        chaptersTable.reloadData()
        selectCurrentTOCRow()
        tocPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

}

private final class MacChapterCellView: NSTableCellView {
    let stateLabel = NSTextField(labelWithString: "")
    let downloadButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "")
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField = title
        stateLabel.font = .preferredFont(forTextStyle: .caption1)
        stateLabel.textColor = .readableSecondaryLabel
        downloadButton.isBordered = false
        downloadButton.imagePosition = .imageOnly
        let row = NSStackView(views: [title, stateLabel, downloadButton])
        // The title takes the free width, so the audio state and button stay on the trailing edge.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
