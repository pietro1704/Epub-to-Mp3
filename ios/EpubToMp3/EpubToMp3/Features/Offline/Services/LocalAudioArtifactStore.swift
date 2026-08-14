import Foundation

/// The single durable record of locally generated audiobook audio.
///
/// A chapter keeps one canonical file URL for its lifetime. Marking a chapter
/// as downloaded promotes its manifest retention only, which prevents a
/// second copy of already-generated audio from consuming storage.
actor LocalAudioArtifactStore {
    static let shared = LocalAudioArtifactStore()
    nonisolated static let didChangeNotification = Notification.Name("LocalAudioArtifactStore.didChange")

    enum ArtifactState: String, Codable, Equatable, Sendable {
        case pending
        case generating
        case waitingForWiFi
        case available
        case failed
    }

    enum Retention: String, Codable, Equatable, Sendable {
        case temporary
        case downloaded
    }

    struct ChapterSeed: Codable, Equatable, Sendable {
        let index: Int
        let title: String
    }

    struct ChapterArtifact: Codable, Equatable, Sendable {
        let index: Int
        var title: String
        var state: ArtifactState
        var retention: Retention
        var playbackRetentionRequested: Bool? = nil
        let relativePath: String
        var byteCount: Int64
        var retryCount: Int
        var lastError: String?
        var updatedAt: Date
    }

    struct Manifest: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let bookID: String
        var bookTitle: String
        var author: String?
        var chapters: [ChapterArtifact]
        var updatedAt: Date
    }

    struct StorageUsage: Equatable, Sendable {
        let temporaryBytes: Int64
        let downloadedBytes: Int64

        var totalBytes: Int64 { temporaryBytes + downloadedBytes }
    }

    /// A compact projection for Settings. The manifest remains the durable
    /// source of truth; this only exposes books that contain protected audio.
    struct DownloadedBook: Equatable, Sendable {
        let bookID: String
        let title: String
        let author: String?
        let chapterCount: Int
        let byteCount: Int64
    }

    enum StoreError: LocalizedError, Equatable {
        case unknownBook(String)
        case unknownChapter(bookID: String, chapterIndex: Int)
        case missingAudioFile(URL)
        case invalidAudioFile(URL)

        var errorDescription: String? {
            switch self {
            case .unknownBook(let bookID):
                return "No local audio manifest exists for \(bookID)."
            case .unknownChapter(let bookID, let chapterIndex):
                return "No local audio chapter \(chapterIndex) exists for \(bookID)."
            case .missingAudioFile(let url):
                return "The local audio file is missing at \(url.path)."
            case .invalidAudioFile(let url):
                return "The local audio file is empty at \(url.path)."
            }
        }
    }

    private static let schemaVersion = 1
    private let root: URL
    private let fileManager: FileManager

    init(root: URL = LocalAudioArtifactStore.defaultRoot()) {
        self.root = root.standardizedFileURL
        self.fileManager = .default
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
        try createDirectoryIfNeeded(root)
        try createDirectoryIfNeeded(chaptersDirectory(bookID: bookID))

        let existing = try loadManifest(bookID: bookID)
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
                    relativePath: relativePath(for: seed.index),
                    byteCount: 0,
                    retryCount: 0,
                    lastError: nil,
                    updatedAt: now
                )
            }
            existing.title = seed.title
            if existing.state == .available, !hasAudioFile(bookID: bookID, artifact: existing) {
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
        try repairFilePolicies(for: manifest)
        try save(manifest)
        return manifest
    }

    func canonicalURL(bookID: String, chapterIndex: Int) throws -> URL {
        let artifact = try requiredArtifact(bookID: bookID, chapterIndex: chapterIndex)
        let directory = chaptersDirectory(bookID: bookID)
        try createDirectoryIfNeeded(directory)
        return bookDirectory(bookID: bookID)
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
        let size = try fileSize(at: url)
        guard size > 0 else {
            throw StoreError.invalidAudioFile(url)
        }
        let shouldRetain = artifact.retention == .downloaded || artifact.playbackRetentionRequested == true
        switch shouldRetain {
        case true:
            try applyDownloadedFilePolicy(to: url)
        case false:
            try applyTemporaryFilePolicy(to: url)
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
        let size = try fileSize(at: url)
        guard size > 0 else {
            throw StoreError.invalidAudioFile(url)
        }
        try applyDownloadedFilePolicy(to: url)
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
        guard let manifest = try loadManifest(bookID: bookID) else { return [] }
        let available = manifest.chapters.filter { artifact in
            artifact.state == .available
                && (chapterIndices == nil || chapterIndices?.contains(artifact.index) == true)
                && hasAudioFile(bookID: bookID, artifact: artifact)
        }
        for artifact in available where artifact.retention != .downloaded {
            try promote(bookID: bookID, chapterIndex: artifact.index)
        }
        return Set(available.map(\.index))
    }

    func artifact(bookID: String, chapterIndex: Int) throws -> ChapterArtifact? {
        guard let manifest = try loadManifest(bookID: bookID) else { return nil }
        return manifest.chapters.first { $0.index == chapterIndex }
    }

    func manifest(bookID: String) throws -> Manifest? {
        guard let manifest = try loadManifest(bookID: bookID) else { return nil }
        try repairFilePolicies(for: manifest)
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
        guard let manifest = try loadManifest(bookID: bookID), !manifest.chapters.isEmpty else {
            return nil
        }
        try repairFilePolicies(for: manifest)
        let chapters = manifest.chapters.sorted { $0.index < $1.index }
        let available = chapters.filter {
            $0.state == .available && hasAudioFile(bookID: bookID, artifact: $0)
        }
        guard !available.isEmpty else {
            return nil
        }
        let chapterProgress = available.map { artifact in
            JobSnapshot.Chapter(
                index: artifact.index,
                name: artifact.title,
                status: "completed",
                downloadUrl: bookDirectory(bookID: bookID)
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
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let bookDirectories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try bookDirectories.compactMap { directory in
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let manifest = try loadManifest(at: directory) else {
                return nil
            }
            let hasTemporaryAudio = manifest.chapters.contains {
                $0.state == .available && $0.retention == .temporary
            }
            return hasTemporaryAudio ? manifest.bookID : nil
        }.sorted()
    }

    func downloadedIndices(bookID: String) throws -> Set<Int> {
        guard let manifest = try loadManifest(bookID: bookID) else { return [] }
        return Set(manifest.chapters.compactMap { artifact in
            guard artifact.retention == .downloaded,
                  artifact.state == .available,
                  hasAudioFile(bookID: bookID, artifact: artifact) else {
                return nil
            }
            return artifact.index
        })
    }

    /// Lists books with audio explicitly kept by the user. Missing files are
    /// excluded so Settings never offers a destructive action for stale state.
    func downloadedBooks() throws -> [DownloadedBook] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            guard let manifest = try? loadManifest(at: directory) else { return nil }
            let downloaded = manifest.chapters.filter {
                $0.retention == .downloaded
                    && $0.state == .available
                    && hasAudioFile(bookID: manifest.bookID, artifact: $0)
            }
            guard !downloaded.isEmpty else { return nil }
            return DownloadedBook(
                bookID: manifest.bookID,
                title: manifest.bookTitle,
                author: manifest.author,
                chapterCount: downloaded.count,
                byteCount: downloaded.reduce(Int64(0)) { $0 + $1.byteCount }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func failedIndices(bookID: String) throws -> [Int] {
        guard let manifest = try loadManifest(bookID: bookID) else { return [] }
        return manifest.chapters.compactMap { artifact in
            artifact.state == .failed ? artifact.index : nil
        }.sorted()
    }

    func hasCompleteDownloadedAudio(bookID: String) throws -> Bool {
        guard let manifest = try loadManifest(bookID: bookID), !manifest.chapters.isEmpty else {
            return false
        }
        return manifest.chapters.allSatisfy {
            $0.retention == .downloaded
                && $0.state == .available
                && hasAudioFile(bookID: bookID, artifact: $0)
        }
    }

    /// Drops only recreatable audio. Explicitly downloaded chapters are never
    /// selected here and therefore remain available after cache maintenance.
    func clearTemporaryAudio(bookID: String) throws {
        guard var manifest = try loadManifest(bookID: bookID) else { return }
        var changed = false
        for index in manifest.chapters.indices where manifest.chapters[index].retention == .temporary {
            let artifact = manifest.chapters[index]
            let url = bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath)
            try? fileManager.removeItem(at: url)
            manifest.chapters[index].state = .pending
            manifest.chapters[index].byteCount = 0
            manifest.chapters[index].lastError = nil
            manifest.chapters[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        manifest.updatedAt = Date()
        try save(manifest)
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
        let url = bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath)
        try? fileManager.removeItem(at: url)
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { entry in
            entry.state = .pending
            entry.retention = .temporary
            entry.byteCount = 0
            entry.lastError = nil
        }
    }

    func clearDownloadedAudio(bookID: String) throws {
        guard let manifest = try loadManifest(bookID: bookID) else { return }
        for artifact in manifest.chapters where artifact.retention == .downloaded {
            try removeDownloadedAudio(bookID: bookID, chapterIndex: artifact.index)
        }
    }

    /// Removes every local artifact for a book when that book leaves the
    /// library. This is intentionally broader than cache eviction: the user
    /// chose to remove the source itself, so no generated audio may survive.
    func removeAllAudio(bookID: String) throws {
        let directory = bookDirectory(bookID: bookID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Evicts only recreatable generated audio. User-promoted downloads are
    /// deliberately excluded from both the byte calculation and deletion.
    @discardableResult
    func evictTemporaryAudio(toMaximumBytes maximumBytes: Int64) throws -> [String] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var candidates: [(bookID: String, artifact: ChapterArtifact, bytes: Int64)] = []
        for directory in directories {
            guard let manifest = try loadManifest(at: directory) else { continue }
            for artifact in manifest.chapters where artifact.state == .available && artifact.retention == .temporary {
                let url = directory.appendingPathComponent(artifact.relativePath)
                let bytes = (try? fileSize(at: url)) ?? 0
                guard bytes > 0 else { continue }
                candidates.append((manifest.bookID, artifact, bytes))
            }
        }
        var bytesInUse = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        var evictedBookIDs: Set<String> = []
        for candidate in candidates.sorted(by: { $0.artifact.updatedAt < $1.artifact.updatedAt })
            where bytesInUse > maximumBytes {
            let url = bookDirectory(bookID: candidate.bookID)
                .appendingPathComponent(candidate.artifact.relativePath)
            try? fileManager.removeItem(at: url)
            try updateArtifact(bookID: candidate.bookID, chapterIndex: candidate.artifact.index) { artifact in
                artifact.state = .pending
                artifact.byteCount = 0
                artifact.lastError = nil
            }
            bytesInUse -= candidate.bytes
            evictedBookIDs.insert(candidate.bookID)
        }
        return evictedBookIDs.sorted()
    }

    func clearAllAudio() throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.removeItem(at: root)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    nonisolated static func temporaryCacheBudgetBytes(root: URL = LocalAudioArtifactStore.defaultRoot()) -> Int64 {
        let hardLimit: Int64 = 2 * 1_024 * 1_024 * 1_024
        let freeBytes = (try? root.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage).map { Int64($0) } ?? hardLimit
        return max(0, min(hardLimit, freeBytes / 10))
    }

    nonisolated static func storageUsage(root: URL = LocalAudioArtifactStore.defaultRoot()) -> StorageUsage {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StorageUsage(temporaryBytes: 0, downloadedBytes: 0)
        }
        var temporaryBytes: Int64 = 0
        var downloadedBytes: Int64 = 0
        for directory in directories {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
                continue
            }
            for artifact in manifest.chapters where artifact.state == .available {
                let url = directory.appendingPathComponent(artifact.relativePath)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
                    .int64Value ?? 0
                if artifact.retention == .downloaded {
                    downloadedBytes += bytes
                } else {
                    temporaryBytes += bytes
                }
            }
        }
        return StorageUsage(temporaryBytes: temporaryBytes, downloadedBytes: downloadedBytes)
    }

    private func requiredArtifact(bookID: String, chapterIndex: Int) throws -> ChapterArtifact {
        guard let manifest = try loadManifest(bookID: bookID) else {
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
        guard var manifest = try loadManifest(bookID: bookID) else {
            throw StoreError.unknownBook(bookID)
        }
        guard let index = manifest.chapters.firstIndex(where: { $0.index == chapterIndex }) else {
            throw StoreError.unknownChapter(bookID: bookID, chapterIndex: chapterIndex)
        }
        update(&manifest.chapters[index])
        manifest.chapters[index].updatedAt = Date()
        manifest.updatedAt = Date()
        try save(manifest)
    }

    private func loadManifest(bookID: String) throws -> Manifest? {
        try loadManifest(at: bookDirectory(bookID: bookID))
    }

    private func loadManifest(at directory: URL) throws -> Manifest? {
        let url = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func save(_ manifest: Manifest) throws {
        let directory = bookDirectory(bookID: manifest.bookID)
        try createDirectoryIfNeeded(directory)
        let url = directory.appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
        try applyManifestFilePolicy(to: url)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: ["bookID": manifest.bookID]
        )
    }

    private func bookDirectory(bookID: String) -> URL {
        root.appendingPathComponent(safePathComponent(bookID), isDirectory: true)
    }

    private func chaptersDirectory(bookID: String) -> URL {
        bookDirectory(bookID: bookID).appendingPathComponent("chapters", isDirectory: true)
    }

    private func relativePath(for chapterIndex: Int) -> String {
        "chapters/chapter-\(chapterIndex).mp3"
    }

    private func hasAudioFile(bookID: String, artifact: ChapterArtifact) -> Bool {
        let url = bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath)
        return ((try? fileSize(at: url)) ?? 0) > 0
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func createDirectoryIfNeeded(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try applyPersistentFilePolicy(to: directory)
    }

    private func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let normalized = raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let collapsed = normalized.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let safe = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? "book" : safe
    }

    private func applyPersistentFilePolicy(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try applyFileProtection(to: url)
    }

    private func applyFileProtection(to url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private func applyManifestFilePolicy(to url: URL) throws {
        try applyPersistentFilePolicy(to: url)
    }

    private func applyTemporaryFilePolicy(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try applyFileProtection(to: url)
    }

    private func applyDownloadedFilePolicy(to url: URL) throws {
        try applyPersistentFilePolicy(to: url)
    }

    private func repairFilePolicies(for manifest: Manifest) throws {
        try createDirectoryIfNeeded(root)
        try createDirectoryIfNeeded(bookDirectory(bookID: manifest.bookID))
        try createDirectoryIfNeeded(chaptersDirectory(bookID: manifest.bookID))
        for artifact in manifest.chapters {
            let url = bookDirectory(bookID: manifest.bookID).appendingPathComponent(artifact.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            switch artifact.retention {
            case .temporary:
                try applyTemporaryFilePolicy(to: url)
            case .downloaded:
                try applyDownloadedFilePolicy(to: url)
            }
        }
    }
}
