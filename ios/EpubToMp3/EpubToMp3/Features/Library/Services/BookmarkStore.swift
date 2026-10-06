import Foundation
import Combine

final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []

    private let defaults: UserDefaults
    private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = "bookmarks.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    // MARK: - Queries

    func bookmarks(for bookId: String) -> [Bookmark] {
        bookmarks.filter { $0.bookId == bookId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func bookmarks(for bookId: String, chapterIndex: Int) -> [Bookmark] {
        bookmarks.filter { $0.bookId == bookId && $0.chapterIndex == chapterIndex }
            .sorted { $0.startChar < $1.startChar }
    }

    func pageBookmarks(for bookId: String) -> [Bookmark] {
        bookmarks(for: bookId).filter { !$0.isHighlight }
    }

    func highlights(for bookId: String) -> [Bookmark] {
        bookmarks(for: bookId).filter { $0.isHighlight }
    }

    // MARK: - Mutations

    @discardableResult
    func addBookmark(
        bookId: String,
        chapterIndex: Int,
        chapterTitle: String,
        startChar: Int = 0,
        endChar: Int = 0,
        selectedText: String = "",
        note: String? = nil,
        color: HighlightColor = .yellow
    ) -> Bookmark {
        let entry = Bookmark(
            id: UUID(),
            bookId: bookId,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            startChar: startChar,
            endChar: endChar,
            selectedText: selectedText,
            note: note,
            color: color,
            createdAt: Date()
        )
        bookmarks.append(entry)
        persist()
        return entry
    }

    func updateNote(id: UUID, note: String?) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].note = note
        persist()
    }

    func updateColor(id: UUID, color: HighlightColor) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].color = color
        persist()
    }

    func remove(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func removeAll(for bookId: String) {
        bookmarks.removeAll { $0.bookId == bookId }
        persist()
    }

    /// Drop every bookmark whose `bookId` is not in `validBookIds`.
    /// Returns the number of orphan entries removed. No-op (and does not
    /// re-persist or notify) when the in-memory set is already clean —
    /// keeps `@Published` updates and disk writes silent on the common
    /// "nothing to prune" path.
    ///
    /// Mirrors the Flutter slice-42 fix: book IDs are SHA-256 of file
    /// content, so an orphan bookmark could resurrect itself if the user
    /// re-imports the same EPUB later.
    @discardableResult
    func pruneOrphans(validBookIds: Set<String>) -> Int {
        let before = bookmarks.count
        let kept = bookmarks.filter { validBookIds.contains($0.bookId) }
        let removed = before - kept.count
        guard removed > 0 else { return 0 }
        bookmarks = kept
        persist()
        return removed
    }

    func hasBookmark(bookId: String, chapterIndex: Int) -> Bool {
        bookmarks.contains { $0.bookId == bookId && $0.chapterIndex == chapterIndex && !$0.isHighlight }
    }

    // MARK: - Persistence

    /// True once `load()` has successfully decoded at least once (or found
    /// no data on disk). Guards `persist()` so a decode failure can never
    /// silently overwrite the stored bookmarks with an empty array.
    private var didLoadSuccessfully = false

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            // No stored data — first launch. Safe to persist later.
            didLoadSuccessfully = true
            return
        }
        do {
            self.bookmarks = try JSONDecoder().decode([Bookmark].self, from: data)
            didLoadSuccessfully = true
        } catch {
            // Log but do NOT clear `bookmarks` — leave it empty and block
            // `persist()` so the on-disk data survives for a future build
            // that can decode it.
            NSLog("[BookmarkStore] decode failed — stored bookmarks preserved on disk: %@", "\(error)")
        }
    }

    private func persist() {
        guard didLoadSuccessfully else {
            NSLog("[BookmarkStore] persist blocked — initial load failed, refusing to overwrite stored data")
            return
        }
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

#if DEBUG
extension BookmarkStore {
    static var previewPopulated: BookmarkStore {
        let suite = "bookmarks.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = BookmarkStore(defaults: defaults)
        store.addBookmark(
            bookId: "preview-1",
            chapterIndex: 1,
            chapterTitle: "Chapter 1",
            selectedText: "",
            color: .yellow
        )
        store.addBookmark(
            bookId: "preview-1",
            chapterIndex: 2,
            chapterTitle: "Chapter 2",
            startChar: 10,
            endChar: 50,
            selectedText: "The old scientists peered at the young man",
            note: "Great opening line",
            color: .blue
        )
        return store
    }
}
#endif
