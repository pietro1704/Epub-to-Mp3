import Foundation

/// Explicit storage cleanup. A thrown error may follow partial cleanup;
/// callers must reload actual storage state instead of claiming full success.
struct AudioStorageMaintenance: Sendable {
    private let artifactStore: LocalAudioArtifactStore
    private let legacyAudiobooksRoot: URL
    private let legacyTTSRoot: URL
    private let downloadManager: AudiobookDownloads?
    private let cancelDownloads: (@Sendable () async -> Void)?
    private let notificationCenter: NotificationCenter
    private let rustOutputs: RustConversionOutputStore

    init(
        artifactStore: LocalAudioArtifactStore = .shared,
        legacyAudiobooksRoot: URL = AudiobookDownloadStorage.audiobooksRoot(),
        legacyTTSRoot: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts", isDirectory: true),
        downloadManager: AudiobookDownloads? = nil,
        cancelDownloads: (@Sendable () async -> Void)? = nil,
        notificationCenter: NotificationCenter = .default,
        rustOutputs: RustConversionOutputStore = .shared
    ) {
        self.artifactStore = artifactStore
        self.legacyAudiobooksRoot = legacyAudiobooksRoot
        self.legacyTTSRoot = legacyTTSRoot
        self.downloadManager = downloadManager
        self.cancelDownloads = cancelDownloads
        self.notificationCenter = notificationCenter
        self.rustOutputs = rustOutputs
    }

    func clearAllDownloads() async throws {
        let manager = downloadManager ?? AudiobookDownloads.shared
        try await manager.withStorageMaintenance {
            await cancelDownloads?()
            try Task.checkCancellation()
            try await rustOutputs.clearAllAudio {
                try await artifactStore.clearAllAudio()
                try removeLegacyRoot(legacyAudiobooksRoot)
                try removeLegacyRoot(legacyTTSRoot)
            }
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
