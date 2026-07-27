import Foundation
import os.log

private let evictionLog = Logger(subsystem: "epub2mp3", category: "CacheEviction")

// MARK: - Configuration constants

/// Maximum on-device cache budget for downloaded audiobooks (bytes).
/// Default 2 GB. Surfaced via `AppSettings.offlineCacheBudgetBytes`.
let defaultOfflineCacheBudgetBytes: Int64 = 2 * 1_024 * 1_024 * 1_024

/// Maximum age for a cached audiobook before it is considered stale.
/// Default 24 hours. Surfaced via `AppSettings.offlineCacheTTLSeconds`.
let defaultOfflineCacheTTLSeconds: TimeInterval = 24 * 60 * 60

/// Process-local protection for cache entries currently in use.
/// Reference counts allow a reader and a download to protect the same job
/// concurrently while releasing their protection independently.
enum CacheActivityRegistry {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var referenceCounts: [String: Int] = [:]
    }

    private static let state = State()

    static func begin(jobId: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        state.referenceCounts[jobId, default: 0] += 1
    }

    static func end(jobId: String) {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let count = state.referenceCounts[jobId] else { return }
        if count <= 1 {
            state.referenceCounts.removeValue(forKey: jobId)
        } else {
            state.referenceCounts[jobId] = count - 1
        }
    }

    static func activeJobIds() -> Set<String> {
        state.lock.lock()
        defer { state.lock.unlock() }
        return Set(state.referenceCounts.keys)
    }
}

struct StorageUsageSnapshot: Equatable, Sendable {
    let offlineAudioBytes: Int64
    let ttsCacheBytes: Int64
    let totalBytes: Int64
    let budgetBytes: Int64

    var budgetFraction: Double {
        guard budgetBytes > 0 else { return 0 }
        return min(1, max(0, Double(totalBytes) / Double(budgetBytes)))
    }
}

enum StorageUsageScanner {
    static func current(budgetBytes: Int64 = defaultOfflineCacheBudgetBytes) -> StorageUsageSnapshot {
        let offline = directorySize(DownloadManager.audiobooksRoot())
        let ttsRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts", isDirectory: true)
        let tts = directorySize(ttsRoot)
        return StorageUsageSnapshot(
            offlineAudioBytes: offline,
            ttsCacheBytes: tts,
            totalBytes: offline + tts,
            budgetBytes: budgetBytes
        )
    }

    static func clearAllDownloads() {
        AudiobookCacheEviction.deleteAllAudiobooks()
        let ttsRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts", isDirectory: true)
        try? FileManager.default.removeItem(at: ttsRoot)
        NotificationCenter.default.post(name: ChapterCacheManager.clearAllNotification, object: nil)
    }

    private static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.reduce(Int64(0)) { total, item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }
}

// MARK: - AudiobookCacheEntry

/// A snapshot of a single cached audiobook's storage metadata,
/// used by the eviction algorithm.
struct AudiobookCacheEntry: Equatable, Sendable {
    let jobId: String
    let totalBytes: Int64
    /// Wall-clock time of last access (read or playback open).
    /// Written by `AudiobookCacheEviction.touchLastAccess(jobId:)`.
    let lastAccessedAt: Date
    let downloadedAt: Date
}

// MARK: - AudiobookCacheEviction

/// LRU + TTL eviction policy for the on-device audiobook cache.
///
/// **Invariants:**
/// - Never touches the audiobook whose `jobId` appears in `activeJobIds`.
/// - Runs best-effort; individual delete failures are logged and skipped.
/// - All filesystem I/O is nonisolated (no actor hop needed for the
///   stateless scan / delete path).
///
/// **Last-access tracking:**
/// Call `touchLastAccess(jobId:)` whenever playback opens an audiobook.
/// The timestamp is stored alongside the manifest in a sidecar file
/// `last_access` (plain ISO-8601 string) inside the audiobook folder so
/// it survives app kills without requiring an actor or CoreData.
enum AudiobookCacheEviction {

    // MARK: Last-access sidecar

    private static func lastAccessURL(for jobId: String, root: URL) -> URL {
        root
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("last_access")
    }

    /// Touch the last-access timestamp for `jobId`.
    /// Safe to call from any thread — no shared mutable state.
    static func touchLastAccess(jobId: String) {
        let url = lastAccessURL(for: jobId, root: DownloadManager.audiobooksRoot())
        let iso = ISO8601DateFormatter().string(from: Date())
        try? iso.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readLastAccess(for jobId: String, root: URL) -> Date? {
        let url = lastAccessURL(for: jobId, root: root)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Entry scan

    /// Enumerate every audiobook folder that has a valid manifest.
    /// Returns an array of `AudiobookCacheEntry` sorted oldest-accessed first
    /// (LRU ordering for eviction candidates).
    static func scanEntries() -> [AudiobookCacheEntry] {
        scanEntries(root: DownloadManager.audiobooksRoot())
    }

    /// Enumerate entries under an explicit root. Keeping the root injectable
    /// makes eviction tests deterministic and prevents them from touching a
    /// user's live Documents directory.
    static func scanEntries(root: URL) -> [AudiobookCacheEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var entries: [AudiobookCacheEntry] = []
        for folder in contents where folder.hasDirectoryPath {
            let jobId = folder.lastPathComponent
            guard let manifest = loadManifest(for: jobId, root: root) else { continue }
            let lastAccess = readLastAccess(for: jobId, root: root)
                ?? manifest.completedAt
                ?? manifest.chapters.first.map(\.downloadedAt)
                ?? Date.distantPast
            entries.append(AudiobookCacheEntry(
                jobId: jobId,
                totalBytes: manifest.totalBytes,
                lastAccessedAt: lastAccess,
                downloadedAt: manifest.completedAt ?? Date.distantPast
            ))
        }
        // LRU first: oldest (least-recently-used) at index 0
        return entries.sorted { $0.lastAccessedAt < $1.lastAccessedAt }
    }

    private static func loadManifest(for jobId: String, root: URL) -> AudiobookManifest? {
        let url = root
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }

        let decoder = JSONDecoder()
        if let manifest = try? decoder.decode(AudiobookManifest.self, from: data) {
            return manifest
        }
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(AudiobookManifest.self, from: data)
    }

    // MARK: Eviction

    /// Run the full eviction pass.
    ///
    /// - Parameters:
    ///   - budgetBytes: Maximum total cache size (bytes). Default = `defaultOfflineCacheBudgetBytes`.
    ///   - ttlSeconds: Maximum age for an entry (seconds). Default = `defaultOfflineCacheTTLSeconds`.
    ///   - activeJobIds: Job IDs currently being played or actively downloading — never evicted.
    ///
    /// Called on app launch and after each completed download.
    /// Best-effort: individual failures are swallowed so the app never crashes.
    @discardableResult
    static func runEviction(
        root: URL? = nil,
        budgetBytes: Int64 = defaultOfflineCacheBudgetBytes,
        ttlSeconds: TimeInterval = defaultOfflineCacheTTLSeconds,
        activeJobIds: Set<String> = []
    ) -> [String] {
        let storageRoot = root ?? DownloadManager.audiobooksRoot()
        let protectedJobIds = activeJobIds.union(CacheActivityRegistry.activeJobIds())
        var entries = scanEntries(root: storageRoot)
        var evicted: [String] = []
        let now = Date()

        // Phase 1: TTL — evict entries older than ttlSeconds, skipping active.
        for entry in entries where !protectedJobIds.contains(entry.jobId) {
            let age = now.timeIntervalSince(entry.lastAccessedAt)
            if age > ttlSeconds {
                if deleteAudiobook(jobId: entry.jobId, root: storageRoot) {
                    evictionLog.info("TTL evicted \(entry.jobId, privacy: .public) age=\(Int(age))s")
                    evicted.append(entry.jobId)
                }
            }
        }

        // Remove evicted entries from the working set for the budget phase.
        entries.removeAll { evicted.contains($0.jobId) }

        // Phase 2: LRU budget — remove oldest entries until under budget.
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.totalBytes }
        for entry in entries where !protectedJobIds.contains(entry.jobId) {
            guard totalBytes > budgetBytes else { break }
            if deleteAudiobook(jobId: entry.jobId, root: storageRoot) {
                totalBytes -= entry.totalBytes
                evictionLog.info("Budget evicted \(entry.jobId, privacy: .public) freed=\(entry.totalBytes)B remaining=\(totalBytes)B")
                evicted.append(entry.jobId)
            }
        }

        return evicted
    }

    // MARK: Library reconcile

    /// Book ids whose `BookEntity.cachedOffline` flag no longer matches
    /// disk truth. Eviction (and Settings → "Clear downloaded audio")
    /// deletes the whole `Audiobooks/<jobId>/` folder — manifest included —
    /// without touching the library, so a silently-evicted book kept
    /// showing as "offline ready". Callers flip `cachedOffline = false`
    /// for every id returned here.
    static func staleOfflineBookIds(books: [BookEntity]) -> [String] {
        books.compactMap { book in
            guard book.cachedOffline else { return nil }
            guard let jobId = book.lastJobId,
                  let manifest = DownloadManager.loadManifest(for: jobId),
                  manifest.completedAt != nil,
                  DownloadManager.locallyDownloadedIndices(for: jobId).count == manifest.chapters.count else {
                return book.id
            }
            return nil
        }
    }

    // MARK: Total size

    /// Sum of `totalBytes` across all valid manifests (fast — no filesystem walk).
    static func totalCachedBytes() -> Int64 {
        scanEntries().reduce(Int64(0)) { $0 + $1.totalBytes }
    }

    // MARK: Delete

    /// Delete the entire folder for `jobId` (chapters + manifest + sidecar).
    /// Returns `true` on success. Errors are logged and swallowed.
    @discardableResult
    static func deleteAudiobook(jobId: String) -> Bool {
        deleteAudiobook(jobId: jobId, root: DownloadManager.audiobooksRoot())
    }

    private static func deleteAudiobook(jobId: String, root: URL) -> Bool {
        let folder = root
            .appendingPathComponent(jobId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: folder)
            return true
        } catch {
            evictionLog.error("Failed to delete \(jobId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Delete every downloaded audiobook folder under the audiobooks root.
    /// Used by Settings → "Clear downloaded audio".
    static func deleteAllAudiobooks() {
        let root = DownloadManager.audiobooksRoot()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }
        for item in items {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                do {
                    try FileManager.default.removeItem(at: item)
                    evictionLog.info("Deleted all: \(item.lastPathComponent, privacy: .public)")
                } catch {
                    evictionLog.error("Failed to delete \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
