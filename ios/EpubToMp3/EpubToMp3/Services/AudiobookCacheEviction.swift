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

    private static func lastAccessURL(for jobId: String) -> URL {
        DownloadManager.audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("last_access")
    }

    /// Touch the last-access timestamp for `jobId`.
    /// Safe to call from any thread — no shared mutable state.
    static func touchLastAccess(jobId: String) {
        let url = lastAccessURL(for: jobId)
        let iso = ISO8601DateFormatter().string(from: Date())
        try? iso.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readLastAccess(for jobId: String) -> Date? {
        let url = lastAccessURL(for: jobId)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return ISO8601DateFormatter().date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Entry scan

    /// Enumerate every audiobook folder that has a valid manifest.
    /// Returns an array of `AudiobookCacheEntry` sorted oldest-accessed first
    /// (LRU ordering for eviction candidates).
    static func scanEntries() -> [AudiobookCacheEntry] {
        let root = DownloadManager.audiobooksRoot()
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var entries: [AudiobookCacheEntry] = []
        for folder in contents where folder.hasDirectoryPath {
            let jobId = folder.lastPathComponent
            guard let manifest = DownloadManager.loadManifest(for: jobId) else { continue }
            let lastAccess = readLastAccess(for: jobId)
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
        budgetBytes: Int64 = defaultOfflineCacheBudgetBytes,
        ttlSeconds: TimeInterval = defaultOfflineCacheTTLSeconds,
        activeJobIds: Set<String> = []
    ) -> [String] {
        var entries = scanEntries()
        var evicted: [String] = []
        let now = Date()

        // Phase 1: TTL — evict entries older than ttlSeconds, skipping active.
        for entry in entries where !activeJobIds.contains(entry.jobId) {
            let age = now.timeIntervalSince(entry.lastAccessedAt)
            if age > ttlSeconds {
                if deleteAudiobook(jobId: entry.jobId) {
                    evictionLog.info("TTL evicted \(entry.jobId, privacy: .public) age=\(Int(age))s")
                    evicted.append(entry.jobId)
                }
            }
        }

        // Remove evicted entries from the working set for the budget phase.
        entries.removeAll { evicted.contains($0.jobId) }

        // Phase 2: LRU budget — remove oldest entries until under budget.
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.totalBytes }
        for entry in entries where !activeJobIds.contains(entry.jobId) {
            guard totalBytes > budgetBytes else { break }
            if deleteAudiobook(jobId: entry.jobId) {
                totalBytes -= entry.totalBytes
                evictionLog.info("Budget evicted \(entry.jobId, privacy: .public) freed=\(entry.totalBytes)B remaining=\(totalBytes)B")
                evicted.append(entry.jobId)
            }
        }

        return evicted
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
        let folder = DownloadManager.audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
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
