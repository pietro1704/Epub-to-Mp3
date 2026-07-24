#if os(iOS)
import PDFKit
import UIKit
import UniformTypeIdentifiers

@MainActor
final class BookOpenScreenController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private var book: BookEntity
    private var onClose: (() -> Void)?
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let audioWarmup: AudioEngineWarmup
    private let chapterTable = UITableView(frame: .zero, style: .plain)
    private let titleLabel = UILabel()
    private let textView = UITextView()
    private let statusLabel = UILabel()
    private var fulltext: EbookFulltext?
    private var selectedChapter = 0
    private var pdfView: PDFView?

    private static let reimportTypes: [UTType] = [.epub, .pdf]

    init(book: BookEntity, onClose: (() -> Void)?, library: LibraryStore, settings: AppSettings, player: AudioPlayer, audioWarmup: AudioEngineWarmup) {
        self.book = book
        self.onClose = onClose
        self.library = library
        self.settings = settings
        self.player = player
        self.audioWarmup = audioWarmup
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

    func update(book: BookEntity, onClose: (() -> Void)?, library: LibraryStore, settings: AppSettings, player: AudioPlayer, audioWarmup: AudioEngineWarmup) {
        self.book = book
        self.onClose = onClose
        loadBook()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fulltext?.chapters.count ?? 0 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "chapter") ?? UITableViewCell(style: .default, reuseIdentifier: "chapter")
        var content = cell.defaultContentConfiguration()
        content.text = fulltext?.chapters[indexPath.row].title
        content.secondaryText = L10n.string("reader.chapter", indexPath.row + 1)
        cell.contentConfiguration = content
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedChapter = indexPath.row
        showChapter(indexPath.row)
    }

    private func configureNativeReader() {
        titleLabel.text = book.resolvedTitle
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: settings.readerPointSize)
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 20, bottom: 32, right: 20)
        chapterTable.dataSource = self
        chapterTable.delegate = self
        let close = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeReader))
        let repick = UIBarButtonItem(title: L10n.string("bookOpen.repick"), style: .plain, target: self, action: #selector(repickBook))
        navigationItem.leftBarButtonItem = close
        navigationItem.rightBarButtonItem = repick
        let scroll = UIScrollView()
        scroll.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        chapterTable.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, chapterTable, scroll])
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
            textView.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            textView.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            textView.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
    }

    private func loadBook() {
        guard isViewLoaded else { return }
        titleLabel.text = book.resolvedTitle
        statusLabel.text = L10n.string("reader.loading")
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try library.openBookFile(id: book.id)
                if book.fileType == .pdf {
                    showPDF(url)
                    return
                }
                let cached = LocalFulltextCache.read(bookId: book.id)
                let payload = cached ?? try await PythonBridge.shared.parseEpub(at: url, bookId: book.id)
                if cached == nil { LocalFulltextCache.save(payload, bookId: book.id) }
                fulltext = payload
                chapterTable.reloadData()
                statusLabel.text = "\(payload.chapters.count)"
                showChapter(min(selectedChapter, max(0, payload.chapters.count - 1)))
            } catch {
                statusLabel.text = error.localizedDescription
                textView.text = ""
            }
        }
    }

    private func showChapter(_ index: Int) {
        guard let chapter = fulltext?.chapters[safe: index] else { return }
        titleLabel.text = chapter.title
        textView.text = chapter.text
        textView.font = .systemFont(ofSize: settings.readerPointSize)
        UserDefaults.standard.set(index, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
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

    @objc private func closeReader() { onClose?() }
    @objc private func repickBook() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.reimportTypes, asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            book = try library.importBook(from: url)
            MainReaderView.setCurrentlyReading(bookID: book.id)
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
#endif
