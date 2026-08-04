#if os(iOS)
import UIKit

/// Per-book management for audio the user explicitly chose to keep offline.
/// It reads the artifact manifest rather than a stale UI snapshot, so every
/// deletion stays scoped to the selected book and requires confirmation.
@MainActor
final class LocalAudioDownloadsScreenController: UITableViewController {
    private let library: LibraryStore
    private let artifactStore: LocalAudioArtifactStore
    private var downloadedBooks: [LocalAudioArtifactStore.DownloadedBook] = []

    init(
        library: LibraryStore,
        artifactStore: LocalAudioArtifactStore = .shared
    ) {
        self.library = library
        self.artifactStore = artifactStore
        super.init(style: .insetGrouped)
        title = L10n.string("settings.manageDownloads")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DownloadedBook")
        tableView.accessibilityIdentifier = "settings.downloadedBooks"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { [weak self] in
            guard let self else { return }
            await self.refreshDownloadedBooks()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(downloadedBooks.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DownloadedBook", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessibilityIdentifier = nil
        guard let book = downloadedBooks[safe: indexPath.row] else {
            content.text = L10n.string("settings.noDownloadedBooks")
            content.secondaryText = nil
            content.image = UIImage(systemName: "arrow.down.circle")
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }

        content.text = book.title
        let chapterText = L10n.string("settings.downloadedChapters", book.chapterCount)
        let storageText = ByteCountFormatter.string(fromByteCount: book.byteCount, countStyle: .file)
        content.secondaryText = [book.author, chapterText, storageText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
        content.image = UIImage(systemName: "book.closed.fill")
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = "settings.downloadedBook.\(book.bookID)"
        cell.accessibilityHint = L10n.string("settings.destructiveActionHint")
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let book = downloadedBooks[safe: indexPath.row] else { return }
        let alert = UIAlertController(
            title: L10n.string("settings.removeBookDownloadConfirmTitle"),
            message: L10n.string("settings.removeBookDownloadConfirmMessage", book.title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: L10n.string("settings.removeBookDownload"),
            style: .destructive
        ) { [weak self] _ in
            self?.removeDownloadedAudio(for: book)
        })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    func refreshDownloadedBooks() async {
        downloadedBooks = (try? await artifactStore.downloadedBooks()) ?? []
        tableView.reloadData()
    }

    private func removeDownloadedAudio(for book: LocalAudioArtifactStore.DownloadedBook) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.artifactStore.clearDownloadedAudio(bookID: book.bookID)
            if var libraryBook = self.library.books.first(where: { $0.id == book.bookID }) {
                libraryBook.cachedOffline = false
                self.library.update(libraryBook)
            }
            await self.refreshDownloadedBooks()
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
