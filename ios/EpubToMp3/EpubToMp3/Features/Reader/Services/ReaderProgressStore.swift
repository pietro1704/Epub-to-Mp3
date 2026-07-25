import Foundation

/// Persists the reader's exact in-chapter scroll position, keyed by
/// `bookId`. `LocalFulltextCache`/`readerCurrentChapterIndexDefaultsKey`
/// only ever remembered *which chapter* was open; this store additionally
/// remembers *where inside it* — the fraction of the scrollable content the
/// user had reached — so reopening a book resumes at the same spot instead
/// of the top of the last chapter.
enum ReaderProgressStore {
    struct Entry: Codable, Equatable {
        let chapterIndex: Int
        let offsetFraction: Double
    }

    private static let storageKey = "readerProgress.v1"

    private static func load(defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func save(_ entries: [String: Entry], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Persists the current chapter + fractional scroll offset (0...1) for
    /// a book. `offsetFraction` is clamped so a transient layout glitch
    /// (negative or >1 content offset during a bounce) can never be stored.
    static func save(
        bookId: String,
        chapterIndex: Int,
        offsetFraction: Double,
        defaults: UserDefaults = .standard
    ) {
        var entries = load(defaults: defaults)
        entries[bookId] = Entry(
            chapterIndex: chapterIndex,
            offsetFraction: min(max(offsetFraction, 0), 1)
        )
        save(entries, defaults: defaults)
    }

    static func read(bookId: String, defaults: UserDefaults = .standard) -> Entry? {
        load(defaults: defaults)[bookId]
    }

    static func evict(bookId: String, defaults: UserDefaults = .standard) {
        var entries = load(defaults: defaults)
        entries.removeValue(forKey: bookId)
        save(entries, defaults: defaults)
    }

    /// Drop any stored progress whose `bookId` is not in `validBookIds`.
    /// Mirrors `BookmarkStore.pruneOrphans(validBookIds:)` /
    /// `LocalFulltextCache.pruneOrphans(validBookIds:)` so a re-imported
    /// EPUB (same SHA-256 book id) can't resurrect stale scroll position
    /// from a previous install, and deleted books don't leak entries.
    @discardableResult
    static func pruneOrphans(validBookIds: Set<String>, defaults: UserDefaults = .standard) -> Int {
        let entries = load(defaults: defaults)
        let kept = entries.filter { validBookIds.contains($0.key) }
        let removed = entries.count - kept.count
        guard removed > 0 else { return 0 }
        save(kept, defaults: defaults)
        return removed
    }
}
