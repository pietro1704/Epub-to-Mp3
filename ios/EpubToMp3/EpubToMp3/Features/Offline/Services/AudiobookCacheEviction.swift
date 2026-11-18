import Foundation

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
}

enum StorageUsageScanner {
    static func current(rustOutputsRoot: URL = RustConversionOutputStore.defaultRoot) -> StorageUsageSnapshot {
        let legacyOffline = directorySize(AudiobookDownloadStorage.audiobooksRoot())
        let ttsRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts", isDirectory: true)
        let artifacts = LocalAudioStorageUsage.storageUsage()
        let offline = legacyOffline + artifacts.downloadedBytes
            + RustConversionOutputStore.storageBytes(at: rustOutputsRoot)
        let tts = directorySize(ttsRoot) + artifacts.temporaryBytes
        return StorageUsageSnapshot(
            offlineAudioBytes: offline,
            ttsCacheBytes: tts,
            totalBytes: offline + tts
        )
    }

    static func clearAllDownloads() async throws {
        try await AudioStorageMaintenance().clearAllDownloads()
    }

    static func clearLegacyTemporaryAudio() {
        let ttsRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts", isDirectory: true)
        try? FileManager.default.removeItem(at: ttsRoot)
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

// MARK: - AudiobookCacheEviction

/// Last-access bookkeeping for legacy audiobook folders.
///
/// Generated or downloaded audio is listener-owned and is never removed by an
/// automatic age or size policy; removal happens only through an explicit
/// user action. Playback still stamps a `last_access` sidecar (plain
/// ISO-8601 string) inside the audiobook folder when it opens a book.
enum AudiobookCacheEviction {
    /// Touch the last-access timestamp for `jobId`.
    /// Safe to call from any thread — no shared mutable state.
    static func touchLastAccess(jobId: String) {
        let url = AudiobookDownloadStorage.audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("last_access")
        let iso = ISO8601DateFormatter().string(from: Date())
        try? iso.write(to: url, atomically: true, encoding: .utf8)
    }
}
