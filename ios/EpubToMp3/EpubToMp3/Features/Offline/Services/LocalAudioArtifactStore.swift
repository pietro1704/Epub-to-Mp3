import Foundation

/// The single durable record of locally generated audiobook audio.
///
/// A chapter keeps one canonical file URL for its lifetime. Promoting a chapter
/// to a download changes its manifest retention only, which prevents a
/// second copy of already-generated audio from consuming storage.
actor LocalAudioArtifactStore {
    static let shared = LocalAudioArtifactStore(visibleCopies: .userVisible)
    nonisolated static let didChangeNotification = Notification.Name("LocalAudioArtifactStore.didChange")

    static let schemaVersion = 1
    // Persistence is also used by the actor's import implementation.
    let files: LocalAudioArtifactFiles
    private var root: URL { files.root }
    private var fileManager: FileManager { files.fileManager }

    /// Where protected downloads are also shown to the listener, if anywhere.
    private let visibleCopies: DownloadedAudioFilesMirror?

    init(root: URL = LocalAudioArtifactStore.defaultRoot(), visibleCopies: DownloadedAudioFilesMirror? = nil) {
        files = LocalAudioArtifactFiles(root: root.standardizedFileURL, fileManager: .default)
        self.visibleCopies = visibleCopies
    }

    /// Shows a protected chapter in the listener's files. The store is already
    /// consistent when this runs, so a failure here never fails the Download.
    func publishVisibleCopy(bookID: String, chapterIndex: Int) {
        do {
            try publishDownloadInFiles(bookID: bookID, chapterIndex: chapterIndex)
        } catch {
            NSLog("Visible download copy failed: %@", error.localizedDescription)
        }
    }

    func publishDownloadInFiles(bookID: String, chapterIndex: Int) throws {
        guard let visibleCopies else { return }
        guard let manifest = try validatedManifest(bookID: bookID),
              let artifact = manifest.chapters.first(where: { $0.index == chapterIndex }),
              artifact.state == .available, artifact.retention == .downloaded,
              files.hasAudioFile(bookID: bookID, artifact: artifact) else { throw CocoaError(.fileNoSuchFile) }
        try visibleCopies.publish(
            files.bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath),
            bookID: bookID, bookTitle: manifest.bookTitle,
            chapterIndex: chapterIndex, chapterTitle: artifact.title)
        // The manifest can change before its visible copy is ready.
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: ["bookID": bookID])
    }

    func downloadedChapterIndicesInFiles(bookID: String) throws -> Set<Int> {
        guard let visibleCopies else { return [] }
        return try downloadedChapterIndices(bookID: bookID)
            .intersection(visibleCopies.publishedChapterIndices(bookID: bookID))
    }

    /// What the listener sees as downloaded: the Files copies where the platform shows them,
    /// otherwise (macOS) the kept audio itself.
    func listenerDownloadedChapterIndices(bookID: String) throws -> Set<Int> {
        visibleCopies == nil ? try downloadedChapterIndices(bookID: bookID)
            : try downloadedChapterIndicesInFiles(bookID: bookID)
    }

    /// "Remove download" for one chapter, or for the whole book when `chapterIndex` is nil.
    func removeListenerDownload(bookID: String, chapterIndex: Int?) throws {
        guard visibleCopies == nil else {
            try withdrawDownloadsFromFiles(bookID: bookID, chapterIndex: chapterIndex)
            return
        }
        let downloaded = try downloadedChapterIndices(bookID: bookID)
        let chapters = chapterIndex.map { downloaded.intersection([$0]) } ?? downloaded
        guard !chapters.isEmpty else { return }
        defer {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: ["bookID": bookID])
        }
        for chapter in chapters.sorted() {
            try removeDownloadedAudio(bookID: bookID, chapterIndex: chapter)
        }
    }

    /// Clears owned Files copies only while their protected audio remains available.
    func withdrawDownloadsFromFiles(bookID: String, chapterIndex: Int?) throws {
        guard let visibleCopies else { return }
        let published = try downloadedChapterIndicesInFiles(bookID: bookID)
        let chapters = chapterIndex.map { published.intersection([$0]) } ?? published
        guard !chapters.isEmpty else { return }
        defer {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil, userInfo: ["bookID": bookID])
        }
        for chapter in chapters.sorted() {
            try visibleCopies.withdraw(bookID: bookID, chapterIndex: chapter)
        }
    }

    func withdrawVisibleCopy(bookID: String, chapterIndex: Int) {
        try? visibleCopies?.withdraw(bookID: bookID, chapterIndex: chapterIndex)
    }

    /// Migration must keep a chapter visible before removing its legacy Files copy.
    func ensureVisibleCopyForLegacyRetirement(
        _ audio: URL, manifest: Manifest, chapter: ChapterArtifact, digest: Data
    ) throws {
        try visibleCopies?.publish(
            audio, bookID: manifest.bookID, bookTitle: manifest.bookTitle,
            chapterIndex: chapter.index, chapterTitle: chapter.title, expectedDigest: digest)
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

    func canonicalURL(bookID: String, chapterIndex: Int) throws -> URL {
        let artifact = try requiredArtifact(bookID: bookID, chapterIndex: chapterIndex)
        let directory = files.chaptersDirectory(bookID: bookID)
        try files.createDirectoryIfNeeded(directory)
        return files.bookDirectory(bookID: bookID)
            .appendingPathComponent(artifact.relativePath)
            .standardizedFileURL
    }

    /// Records durable-retention intent only after a chapter has become audible.
    /// A completed file is promoted immediately. For a chapter without playable
    /// audio the intent stays persisted, and explicit removal clears it.
    func requestPlaybackRetention(bookID: String, chapterIndex: Int) throws {
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.playbackRetentionRequested = true
        }
        _ = try promoteAvailable(bookID: bookID, chapterIndices: [chapterIndex])
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
        let wasDownloaded = try requiredArtifact(bookID: bookID, chapterIndex: chapterIndex).retention == .downloaded
        try updateArtifact(bookID: bookID, chapterIndex: chapterIndex) { artifact in
            artifact.state = .available
            artifact.retention = .downloaded
            artifact.byteCount = size
            artifact.lastError = nil
        }
        // A copy the listener deleted is not brought back by a repeated promotion.
        if !wasDownloaded { publishVisibleCopy(bookID: bookID, chapterIndex: chapterIndex) }
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
                completedAt: artifact.updatedAt.timeIntervalSince1970,
                textOffset: artifact.textOffset
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
            lastActivityAt: manifest.updatedAt.timeIntervalSince1970,
            chapterIndexBase: 0
        )
    }

    func temporaryBookIDsEligibleForEviction() throws -> [String] {
        try LocalAudioStorageSummary(files: files).temporaryBookIDsEligibleForEviction()
    }

    func downloadedBooks() throws -> [DownloadedBook] {
        try LocalAudioStorageSummary(files: files).downloadedBooks()
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
        withdrawVisibleCopy(bookID: bookID, chapterIndex: chapterIndex)
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
        try? visibleCopies?.withdrawBook(bookID: bookID)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func clearAllAudio() throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        try fileManager.removeItem(at: root)
        try? visibleCopies?.withdrawAll()
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
