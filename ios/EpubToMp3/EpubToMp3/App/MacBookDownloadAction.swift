#if os(macOS)
import AppKit

/// Library "Download" for one book, acting directly without an intermediate
/// screen. Audio is resolved by book and job identity, never by title.
@MainActor
struct MacBookDownloadAction {
    typealias SnapshotLoader = @MainActor (String) async -> JobSnapshot?
    typealias Enqueuer = @MainActor (JobSnapshot) async -> Void

    let library: LibraryStore
    /// The snapshot currently loaded in the player, if any.
    let currentSnapshot: () -> JobSnapshot?
    /// The book and job of a live local streaming session that has not been recorded yet.
    let streamingOwner: () -> (bookID: String, jobID: String)?
    let presentUnavailable: () -> Void
    var loadSnapshot: SnapshotLoader = MacBookDownloadAction.persistedSnapshot
    var enqueue: Enqueuer = { await AudiobookDownloads.shared.enqueueAll(snapshot: $0, baseURL: nil) }

    /// Returns whether a snapshot with playable chapters was enqueued.
    @discardableResult
    func download(bookID: String) async -> Bool {
        guard let book = library.books.first(where: { $0.id == bookID }) else { return false }
        if let live = ownedLiveSnapshot(for: book), !live.playableChapters.isEmpty {
            await enqueue(live)
            return true
        }
        guard let jobID = book.lastJobId else {
            presentUnavailable()
            return false
        }
        let persisted = await loadSnapshot(jobID)
        // The book may have been removed or reconverted while the snapshot loaded.
        guard library.books.first(where: { $0.id == bookID })?.lastJobId == jobID else { return false }
        guard let persisted, persisted.jobId == jobID, !persisted.playableChapters.isEmpty else {
            presentUnavailable()
            return false
        }
        await enqueue(persisted)
        return true
    }

    private func ownedLiveSnapshot(for book: BookEntity) -> JobSnapshot? {
        guard let snapshot = currentSnapshot() else { return nil }
        if let jobID = book.lastJobId, snapshot.jobId == jobID { return snapshot }
        // Retained embedded audio is identified by the book itself, never by title.
        if snapshot.jobId == "embedded-\(book.id)" { return snapshot }
        if let owner = streamingOwner(), owner.bookID == book.id, owner.jobID == snapshot.jobId { return snapshot }
        return nil
    }

    nonisolated static func persistedSnapshot(jobID: String) async -> JobSnapshot? {
        await Task.detached(priority: .utility) {
            AudiobookDownloadStorage.restoredPlaybackSnapshot(
                jobId: jobID,
                conversionSnapshot: RustConversionCoordinator.persistedSnapshot(jobID: jobID))
        }.value
    }

    static func presentUnavailable(in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = L10n.string("bookDetail.download")
        alert.informativeText = L10n.string("bookDetail.downloadRequiresConversion")
        alert.addButton(withTitle: L10n.string("common.ok"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
#endif
