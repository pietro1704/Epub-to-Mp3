import Foundation

/// The single durable record of locally generated audiobook audio.
///
/// A chapter keeps one canonical file URL for its lifetime. Marking a chapter
/// as downloaded promotes its manifest retention only, which prevents a
/// second copy of already-generated audio from consuming storage.
actor LocalAudioArtifactStore {
    static let shared = LocalAudioArtifactStore()
    nonisolated static let didChangeNotification = Notification.Name("LocalAudioArtifactStore.didChange")

    private static let schemaVersion = 1
    private let files: LocalAudioArtifactFiles
    private var root: URL { files.root }
    private var fileManager: FileManager { files.fileManager }

    init(root: URL = LocalAudioArtifactStore.defaultRoot()) {
        files = LocalAudioArtifactFiles(root: root.standardizedFileURL, fileManager: .default)
    }

    nonisolated static func defaultRoot() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return support
            .appendingPathComponent("EpubToMp3", isDirectory: true)
            .appendingPathComponent("LocalAudioArtifacts", isDirectory: true)
    }

    @discardableResult
    func prepare(
        bookID: String,
        bookTitle: String,
        author: String?,
        chapters: [ChapterSeed]
    ) throws -> Manifest {
        try files.createDirectoryIfNeeded(root)
        try files.createDirectoryIfNeeded(files.chaptersDirectory(bookID: bookID))

        let existing = try files.loadManifest(bookID: bookID)
        let existingByIndex = Dictionary(
            uniqueKeysWithValues: (existing?.chapters ?? []).map { ($0.index, $0) }
        )
        let now = Date()
        let artifacts = chapters.sorted { $0.index < $1.index }.map { seed -> ChapterArtifact in
            guard var existing = existingByIndex[seed.index] else {
                return ChapterArtifact(
                    index: seed.index,
                    title: seed.title,
                    state: .pending,
                    retention: .temporary,
                    relativePath: files.relativePath(for: seed.index),
                    byteCount: 0,
                    retryCount: 0,
                    lastError: nil,
                    updatedAt: now
                )
            }
            existing.title = seed.title
            if existing.state == .available, !files.hasAudioFile(bookID: bookID, artifact: existing) {
                existing.state = .pending
                existing.byteCount = 0
                existing.updatedAt = now
            }
            return existing
        }
        let manifest = Manifest(
            schemaVersion: Self.schemaVersion,
            bookID: bookID,
            bookTitle: bookTitle,
            author: author,
            chapters: artifacts,
            updatedAt: now
        )
        try files.repairFilePolicies(for: manifest)
        try files.save(manifest)
        return manifest
    }

    func canonicalURL(bookID: String, chapterIndex: Int) throws -> URL {
        let artifact = try requiredArtifact(bookID: bookID, chapterIndex: chapterIndex)
        let directory = files.chaptersDirectory(bookID: bookID)
        try files.createDirectoryIfNeeded(directory)
        return files.bookDirectory(bookID: bookID)
            .appendingPathComponent(artifact.relativePath)
            .standardizedFileURL
    }

    func markGenerating(bookID: String, chapterIndex: Int) throws {
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.state = .generating
            artifact.lastError = nil
        }
    }

    func markWaitingForWiFi(bookID: String, chapterIndex: Int) throws {
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.state = .waitingForWiFi
        }
    }

    func markAvailable(bookID: String, chapterIndex: Int) throws {
        let artifact = try requiredArtifact(bookID: bookID, chapterIndex: chapterIndex)
        let url = try canonicalURL(bookID: bookID, chapterIndex: chapterIndex)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.missingAudioFile(url)
        }
        let size = try files.fileSize(at: url)
        guard size > 0 else {
            throw StoreError.invalidAudioFile(url)
        }
        let shouldRetain = artifact.retention == .downloaded || artifact.playbackRetentionRequested == true
        switch shouldRetain {
        case true:
            try files.applyDownloadedFilePolicy(to: url)
        case false:
            try files.applyTemporaryFilePolicy(to: url)
        }
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.state = .available
            if artifact.playbackRetentionRequested == true {
                artifact.retention = .downloaded
            }
            artifact.byteCount = size
            artifact.lastError = nil
        }
    }

    /// Records durable-retention intent only after a chapter has become audible.
    /// A completed file is promoted immediately; an in-flight conversion is
    /// promoted by `markAvailable` when its canonical MP3 arrives.
    func requestPlaybackRetention(bookID: String, chapterIndex: Int) throws {
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.playbackRetentionRequested = true
        }
        _ = try promoteAvailable(bookID: bookID, chapterIndices: [chapterIndex])
    }

    func markFailed(
        bookID: String,
        chapterIndex: Int,
        errorDescription: String
    ) throws {
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.state = .failed
            artifact.retryCount += 1
            artifact.lastError = errorDescription
        }
    }

    func promote(bookID: String, chapterIndex: Int) throws {
        let url = try canonicalURL(bookID: bookID, chapterIndex: chapterIndex)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.missingAudioFile(url)
        }
        let size = try files.fileSize(at: url)
        guard size > 0 else {
            throw StoreError.invalidAudioFile(url)
        }
        try files.applyDownloadedFilePolicy(to: url)
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.state = .available
            artifact.retention = .downloaded
            artifact.byteCount = size
            artifact.lastError = nil
        }
    }

    /// Promotes already-created playable audio before a new conversion request
    /// is enqueued. This keeps a user-selected chapter from waiting behind an
    /// active streaming conversion just to become a durable download.
    func promoteAvailable(bookID: String, chapterIndices: Set<Int>? = nil) throws -> Set<Int> {
        guard let manifest = try files.loadManifest(bookID: bookID) else { return [] }
        let available = manifest.chapters.filter { artifact in
            artifact.state == .available
                && (chapterIndices == nil || chapterIndices?.contains(artifact.index) == true)
                && files.hasAudioFile(bookID: bookID, artifact: artifact)
        }
        for artifact in available where artifact.retention != .downloaded {
            try promote(bookID: bookID, chapterIndex: artifact.index)
        }
        return Set(available.map(\.index))
    }

    func artifact(bookID: String, chapterIndex: Int) throws -> ChapterArtifact? {
        guard let manifest = try files.loadManifest(bookID: bookID) else { return nil }
        return manifest.chapters.first { $0.index == chapterIndex }
    }

    func manifest(bookID: String) throws -> Manifest? {
        guard let manifest = try files.loadManifest(bookID: bookID) else { return nil }
        try files.repairFilePolicies(for: manifest)
        return manifest
    }

    /// Produces the player-compatible representation of every playable local
    /// chapter, even while the rest of the book is still converting. The
    /// manifest remains the durable source of truth; this projection is
    /// recreated when the app launches instead of persisted as a second,
    /// competing record.
    func playableSnapshot(
        bookID: String,
        engine: String,
        voice: String,
        language: String?
    ) throws -> JobSnapshot? {
        guard let manifest = try files.loadManifest(bookID: bookID), !manifest.chapters.isEmpty else {
            return nil
        }
        try files.repairFilePolicies(for: manifest)
        let chapters = manifest.chapters.sorted { $0.index < $1.index }
        let available = chapters.filter {
            $0.state == .available && files.hasAudioFile(bookID: bookID, artifact: $0)
        }
        guard !available.isEmpty else {
            return nil
        }
        let chapterProgress = available.map { artifact in
            JobSnapshot.Chapter(
                index: artifact.index,
                name: artifact.title,
                status: "completed",
                downloadUrl: files.bookDirectory(bookID: bookID)
                    .appendingPathComponent(artifact.relativePath)
                    .absoluteString,
                chars: nil,
                charsProcessed: nil,
                progressRatio: 1,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: artifact.updatedAt.timeIntervalSince1970
            )
        }
        return JobSnapshot(
            jobId: "embedded-\(bookID)",
            state: available.count == chapters.count ? "finished" : "partial",
            bookTitle: manifest.bookTitle,
            bookAuthor: manifest.author,
            coverUrl: nil,
            coverMimeType: nil,
            engine: engine,
            voice: voice,
            language: language,
            progressPercent: Double(available.count) / Double(chapters.count) * 100,
            chaptersTotal: chapters.count,
            chaptersCompleted: chapterProgress.count,
            chapterProgress: chapterProgress,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: manifest.updatedAt.timeIntervalSince1970
        )
    }

    /// Returns a snapshot only when every chapter is local and playable.
    /// Callers that can continue conversion use `playableSnapshot` instead.
    func completedSnapshot(
        bookID: String,
        engine: String,
        voice: String,
        language: String?
    ) throws -> JobSnapshot? {
        guard let snapshot = try playableSnapshot(
            bookID: bookID,
            engine: engine,
            voice: voice,
            language: language
        ), snapshot.state == "finished" else {
            return nil
        }
        return snapshot
    }

    func temporaryBookIDsEligibleForEviction() throws -> [String] {
        try LocalAudioStorageSummary(files: files).temporaryBookIDsEligibleForEviction()
    }

    func downloadedIndices(bookID: String) throws -> Set<Int> {
        guard let manifest = try files.loadManifest(bookID: bookID) else { return [] }
        return Set(manifest.chapters.compactMap { artifact in
            guard artifact.retention == .downloaded,
                  artifact.state == .available,
                  files.hasAudioFile(bookID: bookID, artifact: artifact) else {
                return nil
            }
            return artifact.index
        })
    }

    func downloadedBooks() throws -> [DownloadedBook] {
        try LocalAudioStorageSummary(files: files).downloadedBooks()
    }

    func failedIndices(bookID: String) throws -> [Int] {
        guard let manifest = try files.loadManifest(bookID: bookID) else { return [] }
        return manifest.chapters.compactMap { artifact in
            artifact.state == .failed ? artifact.index : nil
        }.sorted()
    }

    func hasCompleteDownloadedAudio(bookID: String) throws -> Bool {
        guard let manifest = try files.loadManifest(bookID: bookID), !manifest.chapters.isEmpty else {
            return false
        }
        return manifest.chapters.allSatisfy {
            $0.retention == .downloaded
                && $0.state == .available
                && files.hasAudioFile(bookID: bookID, artifact: $0)
        }
    }

    /// Drops only recreatable audio. Explicitly downloaded chapters are never
    /// selected here and therefore remain available after cache maintenance.
    func clearTemporaryAudio(bookID: String) throws {
        guard var manifest = try files.loadManifest(bookID: bookID) else { return }
        var changed = false
        for index in manifest.chapters.indices where manifest.chapters[index].retention == .temporary {
            let artifact = manifest.chapters[index]
            let url = files.bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath)
            do {
                try fileManager.removeItem(at: url)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && error.code == NSFileNoSuchFileError {
                // Already absent audio can still have stale manifest state.
            }
            manifest.chapters[index].state = .pending
            manifest.chapters[index].byteCount = 0
            manifest.chapters[index].lastError = nil
            manifest.chapters[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        manifest.updatedAt = Date()
        try files.save(manifest)
    }

    /// Clears only recreatable generated audio. User-promoted downloads keep
    /// their canonical files and manifest entries intact.
    func clearTemporaryAudio() throws {
        let bookIDs = try temporaryBookIDsEligibleForEviction()
        for bookID in bookIDs {
            try clearTemporaryAudio(bookID: bookID)
        }
    }

    /// Removes an explicit download and its canonical file. The chapter
    /// returns to a pending state so a later download request can regenerate
    /// it deliberately.
    func removeDownloadedAudio(bookID: String, chapterIndex: Int) throws {
        let artifact = try requiredArtifact(bookID: bookID, chapterIndex: chapterIndex)
        guard artifact.retention == .downloaded else { return }
        let url = files.bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath)
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // A missing file still needs its stale download metadata cleared.
        }
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { entry in
            entry.state = .pending
            entry.retention = .temporary
            entry.playbackRetentionRequested = false
            entry.byteCount = 0
            entry.lastError = nil
        }
    }

    func clearDownloadedAudio(bookID: String) throws {
        guard let manifest = try files.loadManifest(bookID: bookID) else { return }
        for artifact in manifest.chapters where artifact.retention == .downloaded {
            try removeDownloadedAudio(bookID: bookID, chapterIndex: artifact.index)
        }
    }

    /// Removes every local artifact for a book when that book leaves the
    /// library. This is intentionally broader than cache eviction: the user
    /// chose to remove the source itself, so no generated audio may survive.
    func removeAllAudio(bookID: String) throws {
        let directory = files.bookDirectory(bookID: bookID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Legacy cache-maintenance entry point.
    ///
    /// Streamed audio is listener media, even before it is explicitly promoted
    /// as a download. Automatic LRU cleanup used to remove it on app launch,
    /// making a previously playable chapter disappear without an explicit
    /// listener decision. Storage management must use the scoped, confirmed
    /// removal actions instead, so this method deliberately performs no I/O.
    @discardableResult
    func evictTemporaryAudio(toMaximumBytes maximumBytes: Int64) throws -> [String] {
        _ = maximumBytes
        return []
    }

    func clearAllAudio() throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.removeItem(at: root)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func requiredArtifact(bookID: String, chapterIndex: Int) throws -> ChapterArtifact {
        guard let manifest = try files.loadManifest(bookID: bookID) else {
            throw StoreError.unknownBook(bookID)
        }
        guard let artifact = manifest.chapters.first(where: { $0.index == chapterIndex }) else {
            throw StoreError.unknownChapter(bookID: bookID, chapterIndex: chapterIndex)
        }
        return artifact
    }

    private func updateArtifact(
        bookID: String,
        chapterIndex: Int,
        update: (inout ChapterArtifact) -> Void
    ) throws {
        guard var manifest = try files.loadManifest(bookID: bookID) else {
            throw StoreError.unknownBook(bookID)
        }
        guard let index = manifest.chapters.firstIndex(where: { $0.index == chapterIndex }) else {
            throw StoreError.unknownChapter(bookID: bookID, chapterIndex: chapterIndex)
        }
        update(&manifest.chapters[index])
        manifest.chapters[index].updatedAt = Date()
        manifest.updatedAt = Date()
        try files.save(manifest)
    }


}
