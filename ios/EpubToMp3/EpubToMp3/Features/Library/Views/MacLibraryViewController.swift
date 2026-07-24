#if os(macOS)
import AppKit
import Combine
import UniformTypeIdentifiers

/// AppKit library surface for macOS. This is intentionally independent of
/// LibraryView so the desktop grid does not pay the SwiftUI diffing and
/// hosting costs of the mobile renderer.
@MainActor
final class MacLibraryViewController: NSViewController, NSSearchFieldDelegate,
    NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let library: LibraryStore
    private let bookmarkStore: BookmarkStore
    private var cancellables: Set<AnyCancellable> = []
    private var sortMode: LibraryGridModel.SortMode = .lastOpened
    private var selectedTag: String?
    private var searchQuery = ""
    private var books: [BookEntity] = []

    private let searchField = NSSearchField()
    private let sortButton = NSPopUpButton()
    private let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton()

    private static let acceptedTypes: [UTType] = {
        var types: [UTType] = [.epub, .pdf]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        return types
    }()

    init(library: LibraryStore, bookmarkStore: BookmarkStore) {
        self.library = library
        self.bookmarkStore = bookmarkStore
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("library.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureToolbar()
        configureCollectionView()
        configureEmptyState()
        bindStore()
        reload()
    }

    private func configureToolbar() {
        searchField.placeholderString = L10n.string("library.searchPlaceholder")
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        sortButton.removeAllItems()
        sortButton.addItems(withTitles: LibraryGridModel.SortMode.allCases.map(\.label))
        sortButton.target = self
        sortButton.action = #selector(sortChanged(_:))
        sortButton.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!,
                           target: self,
                           action: #selector(addTapped))
        add.bezelStyle = .texturedRounded
        add.toolTip = L10n.string("library.addBook")
        add.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)
        view.addSubview(sortButton)
        view.addSubview(add)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            sortButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 8),
            sortButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            add.leadingAnchor.constraint(equalTo: sortButton.trailingAnchor, constant: 8),
            add.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            add.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func configureCollectionView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.delegate = self
        collectionView.dataSource = self
        collectionView.register(MacBookCollectionItem.self,
                                forItemWithIdentifier: MacBookCollectionItem.reuseIdentifier)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 180, height: 270)
        layout.minimumInteritemSpacing = 18
        layout.minimumLineSpacing = 24
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collectionView.collectionViewLayout = layout
        scrollView.documentView = collectionView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureEmptyState() {
        emptyLabel.stringValue = [
            L10n.string("library.emptyTitle"),
            "",
            L10n.string("library.emptyDescription"),
        ].joined(separator: "\n")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = L10n.string("library.addBook")
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.isHidden = true
        addButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        view.addSubview(addButton)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            addButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            addButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 18),
        ])
    }

    private func bindStore() {
        library.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
    }

    private func reload() {
        let model = LibraryGridModel(
            books: library.books,
            selectedTag: selectedTag,
            searchQuery: searchQuery,
            sortMode: sortMode
        )
        books = model.arrangedBooks()
        collectionView.reloadData()
        let empty = books.isEmpty
        collectionView.isHidden = empty
        emptyLabel.isHidden = !empty || !library.books.isEmpty
        addButton.isHidden = !empty || !library.books.isEmpty
    }

    @objc
    private func sortChanged(_ sender: NSPopUpButton) {
        let modes = LibraryGridModel.SortMode.allCases
        guard sender.indexOfSelectedItem < modes.count else { return }
        sortMode = modes[sender.indexOfSelectedItem]
        reload()
    }

    @objc
    private func addTapped() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.acceptedTypes
        guard panel.runModal() == .OK else { return }
        var firstError: Error?
        for url in panel.urls {
            do { _ = try library.importBook(from: url) }
            catch { firstError = firstError ?? error }
        }
        if let firstError {
            presentError(firstError)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    func controlTextDidChange(_ notification: Notification) {
        searchQuery = searchField.stringValue
        reload()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int { books.count }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: MacBookCollectionItem.reuseIdentifier,
                                            for: indexPath)
        guard let bookItem = item as? MacBookCollectionItem else { return item }
        bookItem.configure(with: books[indexPath.item])
        return bookItem
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        let book = books[indexPath.item]
        UserDefaults.standard.set(book.id, forKey: "currentlyReadingBookID")
        var updated = book
        updated.lastOpenedAt = Date()
        library.update(updated)
    }

    func collectionView(_ collectionView: NSCollectionView,
                        menuForItemsAt indexPaths: Set<IndexPath>) -> NSMenu? {
        guard let indexPath = indexPaths.first else { return nil }
        let book = books[indexPath.item]
        let menu = NSMenu()
        let remove = NSMenuItem(title: L10n.string("library.removeFromLibrary"),
                                action: #selector(removeSelectedBook(_:)),
                                keyEquivalent: "")
        remove.target = self
        remove.representedObject = book.id
        menu.addItem(remove)
        return menu
    }

    @objc
    private func removeSelectedBook(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        bookmarkStore.removeAll(for: id)
        LocalFulltextCache.evict(bookId: id)
        if let jobID = library.books.first(where: { $0.id == id })?.lastJobId {
            FulltextStore.evict(jobId: jobID)
        }
        library.remove(id: id)
    }
}

private final class MacBookCollectionItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("MacBookCollectionItem")
    private let coverView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let authorField = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView()
        coverView.imageScaling = .scaleProportionallyUpOrDown
        coverView.imageAlignment = .alignCenter
        coverView.wantsLayer = true
        coverView.layer?.cornerRadius = 8
        coverView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        coverView.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 2
        authorField.textColor = .secondaryLabelColor
        authorField.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [coverView, titleField, authorField])
        stack.orientation = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            coverView.heightAnchor.constraint(equalToConstant: 210),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func configure(with book: BookEntity) {
        titleField.stringValue = book.resolvedTitle
        authorField.stringValue = book.author ?? ""
        authorField.isHidden = book.author?.isEmpty ?? true
        coverView.image = book.coverPNG.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: book.fileType == .pdf ? "doc.richtext" : "book.closed",
                       accessibilityDescription: nil)
    }
}
#endif
