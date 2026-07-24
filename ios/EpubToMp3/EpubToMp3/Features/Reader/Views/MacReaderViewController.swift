#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import Combine
import PDFKit

@MainActor
final class MacReaderViewController: NSSplitViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let chaptersTable = NSTableView()
    private let chapterScrollView = NSScrollView()
    private let textView = NSTextView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var pdfView: PDFView?
    private var fulltext: EbookFulltext?
    private var selectedChapter = 0
    private var cancellables: Set<AnyCancellable> = []

    init(library: LibraryStore, settings: AppSettings, player: AudioPlayer) {
        self.library = library
        self.settings = settings
        self.player = player
        super.init(nibName: nil, bundle: nil)
        dividerStyle = .thin
        splitViewItems = [makeChapterPane(), makeContentPane()]
        library.$books.sink { [weak self] _ in self?.loadCurrentBook() }.store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadCurrentBook()
    }

    func setBook(_ bookID: String?) {
        UserDefaults.standard.set(bookID, forKey: MainReaderView.currentlyReadingBookIDKey)
        loadCurrentBook()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { fulltext?.chapters.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("MacChapterCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            cell.textField = NSTextField(labelWithString: "")
            cell.textField?.lineBreakMode = .byTruncatingTail
            cell.addSubview(cell.textField!)
            cell.textField?.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cell.textField!.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                cell.textField!.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                cell.textField!.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = fulltext?.chapters[row].title ?? ""
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = chaptersTable.selectedRow
        guard row >= 0 else { return }
        selectedChapter = row
        showChapter(row)
    }

    private func makeChapterPane() -> NSSplitViewItem {
        let controller = NSViewController()
        let title = NSTextField(labelWithString: L10n.string("reader.contents"))
        title.font = .boldSystemFont(ofSize: 14)
        let header = NSStackView(views: [title])
        header.orientation = .horizontal
        header.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 8, right: 12)
        chaptersTable.headerView = nil
        chaptersTable.delegate = self
        chaptersTable.dataSource = self
        chaptersTable.usesAlternatingRowBackgroundColors = true
        chaptersTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("chapter")))
        chapterScrollView.documentView = chaptersTable
        chapterScrollView.hasVerticalScroller = true
        let stack = NSStackView(views: [header, chapterScrollView])
        stack.orientation = .vertical
        stack.alignment = .stretch
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view = stack
        return NSSplitViewItem(viewController: controller)
    }

    private func makeContentPane() -> NSSplitViewItem {
        let controller = NSViewController()
        titleLabel.font = .boldSystemFont(ofSize: 22)
        statusLabel.textColor = .secondaryLabelColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 17)
        textView.textContainerInset = NSSize(width: 28, height: 24)
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        let stack = NSStackView(views: [titleLabel, statusLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .stretch
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 18, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controller.view = stack
        return NSSplitViewItem(viewController: controller)
    }

    private func loadCurrentBook() {
        guard isViewLoaded else { return }
        let id = UserDefaults.standard.string(forKey: MainReaderView.currentlyReadingBookIDKey)
        guard let book = library.books.first(where: { $0.id == id }) else {
            fulltext = nil
            textView.string = ""
            titleLabel.stringValue = L10n.string("library.empty.title")
            statusLabel.stringValue = L10n.string("reader.selectBook")
            chaptersTable.reloadData()
            return
        }
        titleLabel.stringValue = book.resolvedTitle
        statusLabel.stringValue = L10n.string("reader.loading")
        Task { [weak self] in
            guard let self else { return }
            do {
                let fileURL = try library.openBookFile(id: book.id)
                if book.fileType == .pdf {
                    await showPDF(fileURL)
                    return
                }
                let payload = LocalFulltextCache.read(bookId: book.id)
                    ?? try await MacEpubParser.parse(at: fileURL, bookId: book.id)
                if LocalFulltextCache.read(bookId: book.id) == nil {
                    LocalFulltextCache.save(payload, bookId: book.id)
                }
                fulltext = payload
                statusLabel.stringValue = "\(payload.chapters.count)"
                chaptersTable.reloadData()
                chaptersTable.selectRowIndexes(IndexSet(integer: min(selectedChapter, max(0, payload.chapters.count - 1))), byExtendingSelection: false)
                showChapter(selectedChapter)
            } catch {
                statusLabel.stringValue = error.localizedDescription
                textView.string = ""
            }
        }
    }

    private func showChapter(_ index: Int) {
        guard let chapter = fulltext?.chapters[safe: index] else { return }
        titleLabel.stringValue = chapter.title
        textView.string = chapter.text
        textView.font = .systemFont(ofSize: settings.readerPointSize)
        textView.scrollToBeginningOfDocument(nil)
        UserDefaults.standard.set(index, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
    }

    private func showPDF(_ url: URL) async {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        pdfView = view
        await MainActor.run {
            statusLabel.stringValue = L10n.string("reader.pdf")
            textView.enclosingScrollView?.documentView = view
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
