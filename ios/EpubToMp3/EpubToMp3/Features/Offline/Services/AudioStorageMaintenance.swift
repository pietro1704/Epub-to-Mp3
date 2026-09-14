import Foundation

/// Explicit storage cleanup. A thrown error may follow partial cleanup;
/// callers must reload actual storage state instead of claiming full success.
struct AudioStorageMaintenance: Sendable {
    private let artifactStore: LocalAudioArtifactStore
    private let legacyAudiobooksRoot: URL
    private let legacyTTSRoot: URL
    private let downloadManager: DownloadManager?
    private let cancelDownloads: (@Sendable () async -> Void)?
    private let notificationCenter: NotificationCenter

    init(
        artifactStore: LocalAudioArtifactStore = .shared,
        legacyAudiobooksRoot: URL = DownloadManager.audiobooksRoot(),
        legacyTTSRoot: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts", isDirectory: true),
        downloadManager: DownloadManager? = nil,
        cancelDownloads: (@Sendable () async -> Void)? = nil,
        notificationCenter: NotificationCenter = .default
    ) {
        self.artifactStore = artifactStore
        self.legacyAudiobooksRoot = legacyAudiobooksRoot
        self.legacyTTSRoot = legacyTTSRoot
        self.downloadManager = downloadManager
        self.cancelDownloads = cancelDownloads
        self.notificationCenter = notificationCenter
    }

    func clearAllDownloads() async throws {
        let manager = downloadManager ?? DownloadManager.shared
        try await manager.withStorageMaintenance {
            await cancelDownloads?()
            try Task.checkCancellation()
            try await artifactStore.clearAllAudio()
            try removeLegacyRoot(legacyAudiobooksRoot)
            try removeLegacyRoot(legacyTTSRoot)
            notificationCenter.post(name: ChapterCacheManager.clearAllNotification, object: nil)
        }
    }

    func clearTemporaryAudio() async throws {
        try await artifactStore.clearTemporaryAudio()
        try removeLegacyRoot(legacyTTSRoot)
        notificationCenter.post(name: ChapterCacheManager.clearAllNotification, object: nil)
    }

    private func removeLegacyRoot(_ root: URL) throws {
        do {
            try FileManager.default.removeItem(at: root)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // Already absent is the only deletion failure equivalent to success.
        }
    }
}
