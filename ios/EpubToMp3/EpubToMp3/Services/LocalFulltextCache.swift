import Foundation

/// On-disk cache of `EbookFulltext` payloads, keyed by `bookId` (the
/// SHA-256 content hash that `LibraryStore` computes). Lives at
/// `~/Library/Caches/<bundle>/fulltext/<bookId>.json`. Sized to free
/// itself when the OS asks: contents under `Caches/` are evictable.
///
/// The first time the user opens a book, `LocalEpubParser` hands a
/// freshly-extracted `EbookFulltext` to `save(...)`. Every subsequent
/// open hits `read(bookId:)` (sub-millisecond JSON load) and the
/// reader paints in one frame.
enum LocalFulltextCache {

    private static var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("fulltext", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        return dir
    }

    private static func fileURL(bookId: String) -> URL? {
        // Sanitise just in case — book ids are SHA-256 hex so this is
        // a defensive belt-and-braces, but cheap.
        let safe = bookId.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        guard !safe.isEmpty else { return nil }
        return directory?.appendingPathComponent("\(safe).json")
    }

    /// Returns the cached fulltext if present and decodable; nil
    /// otherwise. Never throws — a corrupt file falls through to a
    /// re-parse on the caller's side.
    static func read(bookId: String) -> EbookFulltext? {
        guard let url = fileURL(bookId: bookId),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(EbookFulltext.self, from: data)
    }

    /// Best-effort save. Errors are swallowed because a missing
    /// fulltext cache is never fatal — the worst case is one extra
    /// re-parse next launch.
    static func save(_ payload: EbookFulltext, bookId: String) {
        guard let url = fileURL(bookId: bookId),
              let data = try? JSONEncoder().encode(payload) else {
            return
        }
        try? data.write(to: url, options: [.atomic])
    }

    /// Drop the cache for a single book.
    static func evict(bookId: String) {
        guard let url = fileURL(bookId: bookId) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
