import Foundation

/// Durable prepared-reader content keyed by the imported book identifier.
///
/// The on-disk payload belongs in Application Support, not Caches: a cache
/// purge must never turn a warm book open back into a cold parse. The two
/// most recently opened payloads also stay in an automatically evictable
/// in-memory cache so returning to a book does not decode JSON again.
enum LocalFulltextCache {
    private final class PayloadBox: NSObject {
        let payload: EbookFulltext

        init(_ payload: EbookFulltext) {
            self.payload = payload
        }
    }

    private static let memoryCache: NSCache<NSString, PayloadBox> = {
        let cache = NSCache<NSString, PayloadBox>()
        cache.countLimit = 2
        cache.name = "com.pietrocode.epubtomp3.warm-reader-content"
        return cache
    }()
    private static let recentBookIDsKey = "readerWarmBookIDs.v1"
    private static let rebuildableCacheBudgetBytes: Int64 = 256 * 1_024 * 1_024

    private static var directory: URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("ReaderFulltext-v1", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        return dir
    }

    /// Existing installs may still have valid v5 payloads in Caches. Read
    /// them once and migrate instead of forcing listeners through a new cold
    /// parse after an app update.
    private static var legacyDirectory: URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return nil }
        return base.appendingPathComponent("fulltext-v5", isDirectory: true)
    }

    private static func sanitizedBookID(_ bookId: String) -> String? {
        let safe = bookId.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        return safe.isEmpty ? nil : safe
    }

    private static func fileURL(bookId: String, in directory: URL?) -> URL? {
        guard let safe = sanitizedBookID(bookId), let directory else { return nil }
        return directory.appendingPathComponent("\(safe).json")
    }

    /// The durable location of one prepared reader payload. Exposed for the
    /// cache contract and diagnostics; callers still use `read` and `save`.
    static func storageURL(bookId: String) -> URL? {
        fileURL(bookId: bookId, in: directory)
    }

    /// Returns a process-warm payload without touching disk. This is the
    /// reader's fast path: it can paint the saved chapter before any security
    /// bookmark or source document is opened.
    static func inMemoryPayload(bookId: String) -> EbookFulltext? {
        memoryCache.object(forKey: bookId as NSString)?.payload
    }

    /// Returns prepared fulltext when it is available locally. A corrupt
    /// payload falls through to the regular parser; it is never fatal.
    static func read(bookId: String) -> EbookFulltext? {
        if let payload = inMemoryPayload(bookId: bookId) {
            return payload
        }

        guard let payload = readPayload(at: storageURL(bookId: bookId))
                ?? readPayload(at: fileURL(bookId: bookId, in: legacyDirectory)) else {
            return nil
        }
        retainInMemory(payload, bookId: bookId)

        // Migrate a legacy Caches payload only after it has decoded cleanly.
        if let durableURL = storageURL(bookId: bookId),
           !FileManager.default.fileExists(atPath: durableURL.path) {
            write(payload, to: durableURL)
        }
        return payload
    }

    /// Saves durable prepared content and keeps it hot for the next open.
    static func save(_ payload: EbookFulltext, bookId: String) {
        retainInMemory(payload, bookId: bookId)
        guard let url = storageURL(bookId: bookId) else { return }
        write(payload, to: url)
        _ = reclaimRebuildablePayloads(
            toMaximumBytes: rebuildableCacheBudgetBytes,
            preservingBookIDs: [bookId]
        )
    }

    /// Records a successful reader open. The retained payload count is capped
    /// by `memoryCache`; these identifiers let the next process prewarm the
    /// same two books from durable storage.
    static func recordWarmOpen(bookId: String) {
        guard sanitizedBookID(bookId) != nil else { return }
        let existing = UserDefaults.standard.stringArray(forKey: recentBookIDsKey) ?? []
        let recents = ([bookId] + existing.filter { $0 != bookId }).prefix(2)
        UserDefaults.standard.set(Array(recents), forKey: recentBookIDsKey)
    }

    /// Best-effort launch prewarm. Call this off the main actor; cache misses
    /// remain cheap and a corrupt entry simply falls through on the next open.
    static func prewarmRecentBooks() {
        let recents = UserDefaults.standard.stringArray(forKey: recentBookIDsKey) ?? []
        for bookID in recents.prefix(2) {
            _ = read(bookId: bookID)
        }
    }

    /// Drop all prepared-reader state for a book when the listener removes it
    /// or explicitly clears its cache.
    static func evict(bookId: String) {
        memoryCache.removeObject(forKey: bookId as NSString)
        removePayload(at: storageURL(bookId: bookId))
        removePayload(at: fileURL(bookId: bookId, in: legacyDirectory))
        let existing = UserDefaults.standard.stringArray(forKey: recentBookIDsKey) ?? []
        UserDefaults.standard.set(existing.filter { $0 != bookId }, forKey: recentBookIDsKey)
    }

    /// Drop any durable payload whose `bookId` is no longer in the library.
    @discardableResult
    static func pruneOrphans(validBookIds: Set<String>) -> Int {
        guard let dir = directory else { return 0 }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var removed = 0
        for url in entries where url.pathExtension == "json" {
            let bookId = url.deletingPathExtension().lastPathComponent
            guard !validBookIds.contains(bookId) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
            memoryCache.removeObject(forKey: bookId as NSString)
        }
        let existing = UserDefaults.standard.stringArray(forKey: recentBookIDsKey) ?? []
        UserDefaults.standard.set(existing.filter { validBookIds.contains($0) }, forKey: recentBookIDsKey)
        return removed
    }

    /// Bounds only parsed reader payloads, which can always be rebuilt from
    /// the source book. Locally generated audiobook audio lives elsewhere and
    /// is deliberately never considered by this reclamation policy.
    @discardableResult
    static func reclaimRebuildablePayloads(
        toMaximumBytes maximumBytes: Int64,
        preservingBookIDs: Set<String> = [],
        directory overrideDirectory: URL? = nil
    ) -> [String] {
        guard let directory = overrideDirectory ?? self.directory else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = entries.compactMap { url -> (bookID: String, url: URL, bytes: Int64, modified: Date)? in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return nil }
            return (
                bookID: url.deletingPathExtension().lastPathComponent,
                url: url,
                bytes: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
        var totalBytes = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        guard totalBytes > maximumBytes else { return [] }

        var removed: [String] = []
        for candidate in candidates.sorted(by: { $0.modified < $1.modified }) {
            guard totalBytes > maximumBytes,
                  !preservingBookIDs.contains(candidate.bookID),
                  (try? FileManager.default.removeItem(at: candidate.url)) != nil
            else { continue }
            totalBytes -= candidate.bytes
            memoryCache.removeObject(forKey: candidate.bookID as NSString)
            removed.append(candidate.bookID)
        }
        return removed
    }

    private static func retainInMemory(_ payload: EbookFulltext, bookId: String) {
        memoryCache.setObject(PayloadBox(payload), forKey: bookId as NSString)
    }

    private static func readPayload(at url: URL?) -> EbookFulltext? {
        guard let url,
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(EbookFulltext.self, from: data)
    }

    private static func write(_ payload: EbookFulltext, to url: URL) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func removePayload(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
