#if os(iOS)
import UIKit
import UniformTypeIdentifiers

@MainActor
final class LibraryScreenController: UIViewController, UIDocumentPickerDelegate, UISearchResultsUpdating, UISearchBarDelegate {
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let playerPresentation: PlayerPresentation
    private let bookmarkStore: BookmarkStore

    private var sortMode: LibraryGridModel.SortMode = .lastOpened
    private var selectedTag: String?
    private var searchQuery = ""
    private let gridController = LibraryGridController(metrics: .init())
    private let emptyStateLabel = UILabel()
    private let addButton = UIButton(type: .system)

    private static let acceptedTypes: [UTType] = SupportedImportTypes.all

    init(
        library: LibraryStore,
        settings: AppSettings,
        player: AudioPlayer,
        playerPresentation: PlayerPresentation,
        bookmarkStore: BookmarkStore
    ) {
        self.library = library
        self.settings = settings
        self.player = player
        self.playerPresentation = playerPresentation
        self.bookmarkStore = bookmarkStore
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("library.title")
        tabBarItem = UITabBarItem(
            title: L10n.string("nav.library"),
            image: UIImage(systemName: "books.vertical"),
            tag: 0
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        configureSearch()
        configureToolbar()
        configureGrid()
        configureEmptyState()
        reloadGrid(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadGrid(animated: true)
    }

    func refreshFromStores() {
        guard isViewLoaded else { return }
        reloadGrid(animated: false)
    }

    private func configureSearch() {
        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = L10n.string("library.searchPlaceholder")
        searchController.searchBar.accessibilityIdentifier = "library.searchBar"
        searchController.searchBar.searchTextField.accessibilityIdentifier = "library.searchField"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false

        // Keep the native UIKit search surface materialized in the deterministic
        // UI-test fixture. Do not add a second search bar: it changes the
        // production layout being exercised and can conceal Auto Layout defects.
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            definesPresentationContext = true
            searchController.isActive = true
            searchController.searchBar.accessibilityValue = "visible"
        }
    }

    private func configureToolbar() {
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "plus.circle.fill"),
                style: .plain,
                target: self,
                action: #selector(addTapped)
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "arrow.up.arrow.down.circle"),
                menu: makeFilterMenu()
            ),
        ]
        navigationItem.rightBarButtonItems?[0].accessibilityLabel = L10n.string("library.addBook")
        navigationItem.rightBarButtonItems?[0].accessibilityHint = L10n.string("library.addBookHint")
        navigationItem.rightBarButtonItems?[1].accessibilityLabel = L10n.string("library.filterBooks")
    }

    private func configureGrid() {
        addChild(gridController)
        gridController.onOpen = { [weak self] book in
            guard let self else { return }
            // Matches the macOS flow: tapping a book opens the reader
            // directly, no intermediate Read/Listen/Download menu.
            // `MainReaderScreenController` already surfaces itself via
            // `IOSRootContainerController` whenever `currentlyReadingBookID`
            // changes (see BookDetailScreenController.tapRead, the mechanism
            // this reuses instead of pushing Book Detail).
            self.library.update(Self.touchLastOpened(book))
            ReaderSessionState.setCurrentlyReading(bookID: book.id)
        }
        gridController.onRemove = { [weak self] book in
            self?.presentRemoveAlert(for: book)
        }
        gridController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridController.view)
        NSLayoutConstraint.activate([
            gridController.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            gridController.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            gridController.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            gridController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        gridController.didMove(toParent: self)
    }

    private func configureEmptyState() {
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.text = [
            L10n.string("library.emptyTitle"),
            "",
            L10n.string("library.emptyDescription"),
        ].joined(separator: "\n")
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.filled()
        config.title = L10n.string("library.addBook")
        config.image = UIImage(systemName: "plus")
        config.imagePadding = 8
        addButton.configuration = config
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        addButton.accessibilityLabel = L10n.string("library.addBook")
        addButton.accessibilityHint = L10n.string("library.addBookHint")
        addButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(emptyStateLabel)
        view.addSubview(addButton)
        NSLayoutConstraint.activate([
            emptyStateLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            emptyStateLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            addButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            addButton.topAnchor.constraint(equalTo: emptyStateLabel.bottomAnchor, constant: 20),
        ])
    }

    private func reloadGrid(animated: Bool) {
        let model = libraryGridModel()
        gridController.apply(model: model, animated: animated)
        let isEmpty = model.arrangedBooks().isEmpty
        emptyStateLabel.isHidden = !isEmpty
        addButton.isHidden = !isEmpty
        gridController.view.isHidden = isEmpty
        navigationItem.rightBarButtonItems?[1].menu = makeFilterMenu()
    }

    private func libraryGridModel() -> LibraryGridModel {
        let mappedSort: LibraryGridModel.SortMode
        switch sortMode {
        case .lastOpened:
            mappedSort = .lastOpened
        case .title:
            mappedSort = .title
        case .addedDate:
            mappedSort = .addedDate
        }
        return LibraryGridModel(
            books: library.books,
            selectedTag: selectedTag,
            searchQuery: searchQuery,
            sortMode: mappedSort
        )
    }

    private func makeFilterMenu() -> UIMenu {
        let sortActions = LibraryGridModel.SortMode.allCases.map { mode in
            UIAction(
                title: mode.label,
                state: mode == sortMode ? .on : .off
            ) { [weak self] _ in
                self?.sortMode = mode
                self?.reloadGrid(animated: true)
            }
        }
        let tagActions: [UIAction] = [
            UIAction(
                title: L10n.string("library.allBooks"),
                state: selectedTag == nil ? .on : .off
            ) { [weak self] _ in
                self?.selectedTag = nil
                self?.reloadGrid(animated: true)
            }
        ] + library.allTags.map { tag in
            UIAction(
                title: tag,
                image: UIImage(systemName: "tag.fill"),
                state: selectedTag == tag ? .on : .off
            ) { [weak self] _ in
                self?.selectedTag = self?.selectedTag == tag ? nil : tag
                self?.reloadGrid(animated: true)
            }
        }
        return UIMenu(children: [
            UIMenu(title: L10n.string("library.sortBy"), options: .displayInline, children: sortActions),
            UIMenu(title: L10n.string("library.tags"), options: .displayInline, children: tagActions),
        ])
    }

    @objc
    private func addTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.acceptedTypes, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        var firstError: String?
        for url in urls {
            do {
                _ = try library.importBook(from: url)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        reloadGrid(animated: true)
        if let firstError {
            presentMessage(title: L10n.string("library.importError"), message: firstError)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text ?? ""
        reloadGrid(animated: false)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        searchQuery = searchText
        reloadGrid(animated: false)
    }

    private func presentRemoveAlert(for book: BookEntity) {
        let alert = UIAlertController(
            title: book.resolvedTitle,
            message: nil,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: L10n.string("library.removeFromLibrary"), style: .destructive) { [weak self] _ in
            self?.remove(book: book)
        })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        present(alert, animated: true)
    }

    private func remove(book: BookEntity) {
        bookmarkStore.removeAll(for: book.id)
        LocalFulltextCache.evict(bookId: book.id)
        if let jobId = book.lastJobId {
            FulltextStore.evict(jobId: jobId)
        }
        library.remove(id: book.id)
        reloadGrid(animated: true)
    }

    private func presentMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("library.ok"), style: .default))
        present(alert, animated: true)
    }

    private static func touchLastOpened(_ book: BookEntity) -> BookEntity {
        var updated = book
        updated.lastOpenedAt = Date()
        return updated
    }
}
#endif
