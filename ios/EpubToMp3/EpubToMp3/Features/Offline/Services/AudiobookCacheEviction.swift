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
        // Visible copies are clones of store audio that is counted below.
        let legacyRoot = AudiobookDownloadStorage.audiobooksRootLocation()
        let legacyFolders = (try? FileManager.default.contentsOfDirectory(
            at: legacyRoot, includingPropertiesForKeys: nil)) ?? []
        let legacyOffline = legacyFolders.filter { !DownloadedAudioFilesMirror.isMirrorFolder($0) }
            .reduce(Int64(0)) { $0 + directorySize($1) }
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
