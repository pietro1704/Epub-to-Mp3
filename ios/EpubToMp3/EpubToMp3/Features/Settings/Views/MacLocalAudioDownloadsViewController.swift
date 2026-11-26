#if os(macOS)
import AppKit

/// The macOS counterpart of the iPhone "manage downloads" screen: one row per
/// book with offline audio, each removed on its own after a confirmation.
@MainActor
final class MacLocalAudioDownloadsViewController: NSViewController {
    private let library: LibraryStore
    private let storage: BookDownloadStorage
    private let removal = BookAudioRemoval()
    private let list = NSStackView()
    private var entries: [BookDownloadStorage.Entry] = []

    init(library: LibraryStore, artifactStore: LocalAudioArtifactStore = .shared,
         retainedRoot: URL = AudiobookDownloadStorage.audiobooksRoot(), downloads: AudiobookDownloads = .shared) {
        self.library = library
        self.storage = BookDownloadStorage(artifacts: artifactStore, retainedRoot: retainedRoot, downloads: downloads)
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("settings.manageDownloads")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.setAccessibilityIdentifier("settings.downloadedBooks")
        MacScrollableStack.install(list, in: view)
        show([])
        Task { [weak self] in await self?.refreshDownloadedBooks() }
    }

    func refreshDownloadedBooks() async {
        do { show(try await storage.entries(books: library.books)) }
        catch { presentFailure(error, title: L10n.string("settings.downloadListFailed")) }
    }

    private func show(_ entries: [BookDownloadStorage.Entry]) {
        self.entries = entries
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let rows = entries.enumerated().map { index, entry -> NSView in
            let book = entry.book
            let detail = [book.author, L10n.string("settings.downloadedChapters", book.chapterCount),
                          ByteCountFormatter.string(fromByteCount: book.byteCount, countStyle: .file)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
            let remove = NSButton(title: L10n.string("settings.removeBookDownload"), target: self,
                                  action: #selector(confirmRemoval(_:)))
            remove.tag = index
            remove.setAccessibilityIdentifier("settings.downloadedBook.remove.\(book.bookID)")
            return MacSettingsSections.row(title: book.title, subtitle: detail, symbol: "book.closed.fill",
                                           accessory: remove)
        }
        let content = rows.isEmpty
            ? MacSettingsSections.footer(L10n.string("settings.noDownloadedBooks"))
            : MacSettingsSections.card(rows)
        list.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    @objc private func confirmRemoval(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag), let window = view.window, window.attachedSheet == nil else { return }
        let entry = entries[sender.tag]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("settings.removeBookDownloadConfirmTitle")
        alert.informativeText = L10n.string("settings.removeBookDownloadConfirmMessage", entry.book.title)
        alert.addButton(withTitle: L10n.string("settings.removeBookDownload"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await self?.removeDownloadedAudio(entry) }
        }
    }

    func removeDownloadedAudio(_ entry: BookDownloadStorage.Entry) async {
        do {
            if try await removal.remove(bookID: entry.book.bookID, using: { [storage] _ in
                try await storage.remove(entry)
            }),
               var book = library.books.first(where: { $0.id == entry.book.bookID }),
               entry.jobID == nil || book.lastJobId == entry.jobID {
                book.cachedOffline = false
                library.update(book)
            }
        } catch is CancellationError {
            // Cancellation leaves the retained-download state unchanged.
        } catch {
            presentFailure(error, title: L10n.string("settings.storageRemovalFailedTitle"))
        }
        await refreshDownloadedBooks()
    }

    private func presentFailure(_ error: Error, title: String) {
        let message = AppErrorReporter.message(error, context: "Download management")
        guard let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
#endif
