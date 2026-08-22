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
        let characterOffset: Int?

        private enum CodingKeys: String, CodingKey { case chapterIndex, offsetFraction, characterOffset }

        init(chapterIndex: Int, offsetFraction: Double, characterOffset: Int? = nil) {
            self.chapterIndex = max(0, chapterIndex)
            self.offsetFraction = offsetFraction
            self.characterOffset = characterOffset
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            chapterIndex = max(0, try container.decode(Int.self, forKey: .chapterIndex))
            offsetFraction = try container.decode(Double.self, forKey: .offsetFraction)
            characterOffset = try container.decodeIfPresent(Int.self, forKey: .characterOffset)
        }
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
        characterOffset: Int? = nil,
        defaults: UserDefaults = .standard
    ) {
        var entries = load(defaults: defaults)
        entries[bookId] = Entry(
            chapterIndex: chapterIndex,
            offsetFraction: min(max(offsetFraction, 0), 1),
            characterOffset: characterOffset
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

    /// XCTest uses this to make a seeded native book start from a known
    /// passage without deleting the imported book itself.
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
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

enum ReaderInitialChapter {
    /// Resolves persisted reader progress against the payload that was just
    /// loaded. An EPUB with no readable chapters is an error state, never a
    /// blank reader surface.
    static func index(selectedChapter: Int, chapterCount: Int) -> Int? {
        guard chapterCount > 0 else { return nil }
        return min(max(selectedChapter, 0), chapterCount - 1)
    }

    /// Skips cover/title boilerplate on a first open while retaining the
    /// persisted index for returning readers.
    static func firstSubstantiveIndex(in chapters: [EbookFulltext.Chapter]) -> Int {
        chapters.firstIndex { ($0.charCount ?? $0.text.count) >= 1_000 } ?? 0
    }

    /// Starts a first-time open at readable prose but always honors a
    /// listener's saved location when it is still within the payload.
    static func index(
        progress: ReaderProgressStore.Entry?,
        in chapters: [EbookFulltext.Chapter]
    ) -> Int? {
        guard let progress else {
            return index(
                selectedChapter: firstSubstantiveIndex(in: chapters),
                chapterCount: chapters.count
            )
        }
        return index(selectedChapter: progress.chapterIndex, chapterCount: chapters.count)
    }
}
