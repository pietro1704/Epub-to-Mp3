#if os(iOS)
import PDFKit
import UIKit
import UniformTypeIdentifiers

@MainActor
final class BookOpenScreenController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate, UIScrollViewDelegate, UITextViewDelegate {
    private var book: BookEntity
    private let library: LibraryStore
    private let settings: AppSettings
    private let bookmarkStore: BookmarkStore
    private let chapterTable = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let textView = UITextView()
    private let scrollView = UIScrollView()
    private let statusLabel = UILabel()
    private var fulltext: EbookFulltext?
    private var selectedChapter = 0
    private var pdfView: PDFView?
    /// Guards against re-seeking the scroll position on every manual
    /// chapter tap — restoration only makes sense once, right after the
    /// book is (re)loaded.
    private var hasRestoredInitialPosition = false

    private static let reimportTypes: [UTType] = [.epub, .pdf]

    init(book: BookEntity, library: LibraryStore, settings: AppSettings, bookmarkStore: BookmarkStore) {
        self.book = book
        self.library = library
        self.settings = settings
        self.bookmarkStore = bookmarkStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNativeReader()
        loadBook()
    }

    func update(book: BookEntity) {
        self.book = book
        hasRestoredInitialPosition = false
        loadBook()
    }

    private var tocRows: [ReaderTocRow] {
        guard let fulltext else { return [] }
        return ReaderTocFlattener.rows(toc: fulltext.toc, chapters: fulltext.chapters)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tocRows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter") ?? UITableViewCell(style: .default, reuseIdentifier: "chapter")
        let row = tocRows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.chapterIndex.map { L10n.string("reader.chapter", $0 + 1) }
        cell.contentConfiguration = content
        cell.indentationLevel = row.level
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let chapterIndex = tocRows[indexPath.row].chapterIndex else { return }
        persistReadingProgress()
        selectedChapter = chapterIndex
        showChapter(chapterIndex)
        scrollView.setContentOffset(.zero, animated: false)
    }

    private func configureNativeReader() {
        titleLabel.text = book.resolvedTitle
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.font = .systemFont(ofSize: settings.readerPointSize)
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 32, right: 20)
        chapterTable.dataSource = self
        chapterTable.delegate = self
        scrollView.delegate = self
        scrollView.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        chapterTable.translatesAutoresizingMaskIntoConstraints = false

        let footnotesButton = UIButton(type: .system)
        footnotesButton.setTitle(L10n.string("reader.footnotes.title"), for: .normal)
        footnotesButton.addTarget(self, action: #selector(showFootnotes), for: .touchUpInside)
        let searchButton = UIButton(type: .system)
        searchButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        searchButton.addTarget(self, action: #selector(promptSearch), for: .touchUpInside)
        let toolsBar = UIStackView(arrangedSubviews: [footnotesButton, UIView(), searchButton])
        toolsBar.axis = .horizontal
        toolsBar.alignment = .center

        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, toolsBar, chapterTable, scrollView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chapterTable.heightAnchor.constraint(equalToConstant: 150),
            textView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            textView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        persistReadingProgress()
    }

    // MARK: - Pagination (viewport snap) + progress restoration

    /// In `.paginated` mode, rounds the scroll destination to the nearest
    /// multiple of the viewport height so a fling lands on a "page"
    /// boundary instead of an arbitrary mid-line offset. `.scrolling` mode
    /// is untouched (free continuous scroll).
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard settings.readerLayout == .paginated else { return }
        let pageHeight = scrollView.bounds.height
        guard pageHeight > 0 else { return }
        let page = (targetContentOffset.pointee.y / pageHeight).rounded()
        let maxY = max(0, scrollView.contentSize.height - pageHeight)
        targetContentOffset.pointee.y = min(max(page * pageHeight, 0), maxY)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        persistReadingProgress()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { persistReadingProgress() }
    }

    private func persistReadingProgress() {
        let scrollable = max(scrollView.contentSize.height - scrollView.bounds.height, 1)
        let fraction = scrollView.contentOffset.y / scrollable
        ReaderProgressStore.save(bookId: book.id, chapterIndex: selectedChapter, offsetFraction: fraction)
    }

    /// Called once, right after a fresh `loadBook()`, to jump back to the
    /// exact chapter + scroll fraction the user left off at. Runs on the
    /// next runloop tick so Auto Layout has already sized `scrollView`.
    private func restoreReadingProgressIfNeeded() {
        guard !hasRestoredInitialPosition else { return }
        hasRestoredInitialPosition = true
        guard let entry = ReaderProgressStore.read(bookId: book.id) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let scrollable = max(self.scrollView.contentSize.height - self.scrollView.bounds.height, 0)
            guard scrollable > 0 else { return }
            self.scrollView.setContentOffset(
                CGPoint(x: 0, y: entry.offsetFraction * scrollable), animated: false
            )
        }
    }

    private func loadBook() {
        guard isViewLoaded else { return }
        titleLabel.text = book.resolvedTitle
        statusLabel.text = L10n.string("reader.loading")
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            showUITestFixture()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try library.openBookFile(id: book.id)
                if book.fileType == .pdf {
                    showPDF(url)
                    return
                }
                let cached = LocalFulltextCache.read(bookId: book.id)
                let payload: EbookFulltext
                if let cached {
                    payload = cached
                } else {
                    payload = try await PythonBridge.shared.parseEpub(at: url, bookId: book.id)
                    LocalFulltextCache.save(payload, bookId: book.id)
                }
                fulltext = payload
                chapterTable.reloadData()
                statusLabel.text = "\(payload.chapters.count)"
                if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
                    selectedChapter = entry.chapterIndex
                }
                showChapter(min(selectedChapter, max(0, payload.chapters.count - 1)))
                restoreReadingProgressIfNeeded()
            } catch {
                statusLabel.text = error.localizedDescription
                textView.text = ""
            }
        }
    }

    private func showUITestFixture() {
        let payload = EbookFulltext(
            jobId: "ui-test-job",
            bookTitle: book.resolvedTitle,
            bookAuthor: book.author,
            chapters: [
                .init(index: 1, name: "Chapter One", text: String(repeating: "Test reader content. ", count: 80), html: nil, css: nil, charCount: 1680, segments: nil),
                .init(index: 2, name: "Chapter Two", text: String(repeating: "Second chapter content. ", count: 80), html: nil, css: nil, charCount: 1920, segments: nil),
            ]
        )
        fulltext = payload
        chapterTable.reloadData()
        statusLabel.text = "\(payload.chapters.count)"
        showChapter(0)
    }

    private func showChapter(_ index: Int) {
        guard let chapter = fulltext?.chapters[safe: index] else { return }
        titleLabel.text = chapter.displayTitle
        if let html = chapter.html,
           let rendered = EpubHtmlRenderer.render(
               html: html, css: chapter.css, settings: settings, resources: chapter.resources
           ) {
            textView.attributedText = NSAttributedString(rendered)
        } else {
            textView.text = chapter.text
            textView.font = .systemFont(ofSize: settings.readerPointSize)
        }
        repaintSavedHighlights(chapterIndex: index)
        UserDefaults.standard.set(index, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
    }

    // MARK: - Selection → bookmark/highlight/note

    /// Repaints every saved highlight for this chapter as a background
    /// tint. Offsets are resolved against the text actually on screen
    /// right now (`ReaderTextHighlight`), not the Python `chapter.text`
    /// pipeline — see the "Known limitations" note on
    /// `EpubHtmlRenderer.render`.
    private func repaintSavedHighlights(chapterIndex: Int) {
        let highlights = bookmarkStore.bookmarks(for: book.id, chapterIndex: chapterIndex).filter { $0.isHighlight }
        guard !highlights.isEmpty, let attributed = textView.attributedText, attributed.length > 0 else { return }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        for bookmark in highlights {
            let span = SentenceSpan(
                id: bookmark.id.uuidString, text: bookmark.selectedText,
                startChar: bookmark.startChar, endChar: bookmark.endChar
            )
            guard let range = ReaderTextHighlight.range(for: span, in: mutable) else { continue }
            mutable.addAttribute(.backgroundColor, value: bookmark.color.platformColor, range: range)
        }
        textView.attributedText = mutable
    }

    @available(iOS 16.0, *)
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard range.length > 0 else { return UIMenu(children: suggestedActions) }
        let selectedText = (textView.text as NSString).substring(with: range)
        let highlight = UIAction(title: L10n.string("reader.action.highlight")) { [weak self] _ in
            self?.addBookmark(range: range, selectedText: selectedText, note: nil)
        }
        let note = UIAction(title: L10n.string("reader.action.addNote")) { [weak self] _ in
            self?.promptForNote(range: range, selectedText: selectedText)
        }
        let bookmarkMenu = UIMenu(title: "", options: .displayInline, children: [highlight, note])
        return UIMenu(children: [bookmarkMenu] + suggestedActions)
    }

    private func promptForNote(range: NSRange, selectedText: String) {
        let alert = UIAlertController(
            title: L10n.string("reader.action.addNote"), message: selectedText, preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = L10n.string("reader.note.placeholder") }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.save"), style: .default) { [weak self, weak alert] _ in
            let note = alert?.textFields?.first?.text
            self?.addBookmark(range: range, selectedText: selectedText, note: note)
        })
        present(alert, animated: true)
    }

    // MARK: - Footnotes

    @objc private func showFootnotes() {
        guard let footnotes = fulltext?.chapters[safe: selectedChapter]?.footnotes, !footnotes.isEmpty else {
            let alert = UIAlertController(
                title: L10n.string("reader.footnotes.title"),
                message: L10n.string("reader.footnotes.empty"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
            return
        }
        let sheet = FootnotesSheetController(footnotes: footnotes)
        present(UINavigationController(rootViewController: sheet), animated: true)
    }

    // MARK: - In-chapter search

    @objc private func promptSearch() {
        let alert = UIAlertController(
            title: L10n.string("reader.search.placeholder"), message: nil, preferredStyle: .alert
        )
        alert.addTextField()
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default) { [weak self, weak alert] _ in
            guard let query = alert?.textFields?.first?.text, !query.isEmpty else { return }
            self?.performSearch(query: query)
        })
        present(alert, animated: true)
    }

    private func performSearch(query: String) {
        let full = (textView.text ?? "") as NSString
        let range = full.range(of: query, options: .caseInsensitive)
        guard range.location != NSNotFound else {
            let alert = UIAlertController(
                title: L10n.string("reader.search.noResults"), message: nil, preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
            return
        }
        textView.selectedRange = range
        textView.scrollRangeToVisible(range)
    }

    private func addBookmark(range: NSRange, selectedText: String, note: String?) {
        bookmarkStore.addBookmark(
            bookId: book.id,
            chapterIndex: selectedChapter,
            chapterTitle: fulltext?.chapters[safe: selectedChapter]?.displayTitle ?? "",
            startChar: range.location,
            endChar: range.location + range.length,
            selectedText: selectedText,
            note: note,
            color: .yellow
        )
        repaintSavedHighlights(chapterIndex: selectedChapter)
    }

    private func showPDF(_ url: URL) {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        pdfView = view
        chapterTable.isHidden = true
        textView.removeFromSuperview()
        self.view.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor), view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor), view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        statusLabel.text = L10n.string("reader.pdf")
    }

    func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.reimportTypes, asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            book = try library.importBook(from: url)
            ReaderSessionState.setCurrentlyReading(bookID: book.id)
            hasRestoredInitialPosition = false
            loadBook()
        } catch {
            let alert = UIAlertController(title: L10n.string("bookOpen.error"), message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Native sheet listing a chapter's footnotes as `{number, text}` pairs.
/// Deliberately does not try to resolve a tap-to-jump from an inline
/// reference — `raw_html` may point at a separate notes document the
/// sanitizer doesn't preserve cross-document, so a plain listing is the
/// robust choice (see `docs/reader-spec-comparison.md` P0 gap #1 notes).
private final class FootnotesSheetController: UITableViewController {
    private let footnotes: [EbookFulltext.Footnote]

    init(footnotes: [EbookFulltext.Footnote]) {
        self.footnotes = footnotes
        super.init(style: .plain)
        title = L10n.string("reader.footnotes.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(dismissSelf)
        )
    }

    @objc private func dismissSelf() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { footnotes.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "footnote") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "footnote")
        let footnote = footnotes[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = footnote.number.map { "#\($0)" } ?? "#\(indexPath.row + 1)"
        content.secondaryText = footnote.text
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        return cell
    }
}
#endif
