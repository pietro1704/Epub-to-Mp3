#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit

@MainActor
final class MacReaderContentsPresentation: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let document: MacReaderDocument
    private let composition: MacReaderViewComposition
    private let persistProgress: () -> Void
    private let showChapter: (Int) -> Void
    private var isSynchronizingTOCSelection = false
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
         persistProgress: @escaping () -> Void, showChapter: @escaping (Int) -> Void) {
        self.document = document
        self.composition = composition
        self.persistProgress = persistProgress
        self.showChapter = showChapter
        super.init()
    }

    private var tocRows: [ReaderTocRow] { document.tocRows }

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
        let controller = NSViewController()
        controller.view = scrollView
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
        tocPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
