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

    func hasBookmark(bookId: String, chapterIndex: Int) -> Bool {
        bookmarks.contains { $0.bookId == bookId && $0.chapterIndex == chapterIndex && !$0.isHighlight }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        self.bookmarks = decoded
    }

    private func persist() {
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
