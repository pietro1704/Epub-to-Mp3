import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-chapter download state for `DownloadManager`.
struct DownloadProgress: Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case queued
        case downloading
        case completed
        case failed
        case paused
        case cancelled
    }

    let jobId: String
    let chapterIndex: Int
    let totalChapters: Int
    let completedChapters: Int
    let bytesDownloaded: Int64
    let bytesExpected: Int64
    let state: State
    let lastError: String?
}

/// Persisted manifest for an audiobook on disk.
/// Lives at `Audiobooks/<jobId>/manifest.json` per the offline-cache-mobile
/// agent contract.
struct AudiobookManifest: Codable, Equatable, Sendable {
    struct ChapterEntry: Codable, Equatable, Sendable {
        let index: Int
        let title: String
        let mp3FileName: String
        let mp3Bytes: Int64
        let downloadedAt: Date
    }

    var jobId: String
    var bookTitle: String
    var chapters: [ChapterEntry]
    var totalBytes: Int64
    var completedAt: Date?
}

/// Background-aware MP3 download manager.
///
/// Actor isolation replaces the manual `NSLock` that previously guarded
/// `progressContinuations` and `lastProgress`. All mutable state is now
/// compile-time checked for data-race safety.
actor DownloadManager {

    static let shared = DownloadManager()

    /// Stable identifier lets iOS reconnect to pending tasks after suspension
    /// or a system relaunch of the app.
    nonisolated static let backgroundSessionIdentifier = "com.pietrocode.epubtomp3.downloads"

    nonisolated static func backgroundSessionConfiguration() -> URLSessionConfiguration {
        #if os(iOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
        #else
        // The macOS host target cannot create an iOS background session.
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
        #endif
    }

    // MARK: Public progress streams

    private var progressContinuations: [String: [UUID: AsyncStream<DownloadProgress>.Continuation]] = [:]
    private var lastProgress: [String: DownloadProgress] = [:]
    private var activeTasks: [String: UUID] = [:]
    private var writingTasks: [UUID: (jobId: String, task: Task<Void, Never>)] = [:]
    private struct DeferredDownload {
        let snapshot: JobSnapshot
        let chapters: [JobSnapshot.Chapter]
        let baseURL: URL?
    }
    private var storageMaintenance: Set<UUID> = []
    private var deferredDownloads: [String: DeferredDownload] = [:]

    func watchProgress(jobId: String) -> AsyncStream<DownloadProgress> {
        let last = lastProgress[jobId]
        return AsyncStream { continuation in
            let id = UUID()
            self.progressContinuations[jobId, default: [:]][id] = continuation
            if let last { continuation.yield(last) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(jobId: jobId, id: id) }
            }
        }
    }

    private func removeContinuation(jobId: String, id: UUID) {
        progressContinuations[jobId]?.removeValue(forKey: id)
    }

    private func emit(_ progress: DownloadProgress) {
        lastProgress[progress.jobId] = progress
        let conts = progressContinuations[progress.jobId]?.values ?? [:].values
        for cont in conts { cont.yield(progress) }
    }

    // MARK: Storage layout (nonisolated — no instance state)

    nonisolated static let audiobooksFolderName = "Audiobooks"
    nonisolated static let applicationSupportFolderName = "EpubToMp3"
    /// Test-only storage injection. Production never assigns this value;
    /// tests use it to keep fixtures out of Documents/Application Support.
    nonisolated(unsafe) static var rootOverrideForTesting: URL?

    nonisolated static func audiobooksRoot() -> URL {
        if let override = rootOverrideForTesting {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let base: URL
        #if os(macOS)
        // App-owned audio must stay inside the sandbox. Reading the user's
        // Documents directory on every launch triggers a macOS privacy prompt
        // even though the user only selected a book once in the file picker.
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        base = support.appendingPathComponent(applicationSupportFolderName, isDirectory: true)
        #else
        base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        let url = base.appendingPathComponent(audiobooksFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func audiobookFolder(for jobId: String) -> URL {
        let url = audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated static func manifestURL(for jobId: String) -> URL {
        audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    nonisolated static func loadManifest(for jobId: String) -> AudiobookManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: jobId)) else { return nil }
        return try? JSONDecoder().decode(AudiobookManifest.self, from: data)
    }

    /// Chapter indices (same axis as `JobSnapshot.Chapter.index`) whose MP3
    /// is actually present on disk for `jobId`. The manifest records what
    /// finished downloading, but eviction or the OS can remove files without
    /// rewriting it — so every entry is re-verified against the filesystem.
    /// This is the source of truth for "downloaded" UI badges; a snapshot's
    /// `downloadUrl` only means the SERVER has the chapter.
    nonisolated static func locallyDownloadedIndices(for jobId: String) -> Set<Int> {
        guard let manifest = loadManifest(for: jobId) else { return [] }
        // This is a read-only query. Do not call `audiobookFolder(for:)`
        // here because that helper creates missing directories, causing
        // filesystem work for every absent/evicted manifest lookup.
        let folder = audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
        let fm = FileManager.default
        return Set(
            manifest.chapters
                .filter { fm.fileExists(atPath: folder.appendingPathComponent($0.mp3FileName).path) }
                .map(\.index)
        )
    }

    nonisolated static func localAudioURL(jobId: String, chapterIndex: Int) -> URL? {
        guard let entry = loadManifest(for: jobId)?.chapters.first(where: { $0.index == chapterIndex }) else { return nil }
        let url = audiobookFolder(for: jobId).appendingPathComponent(entry.mp3FileName)
        guard FileManager.default.fileExists(atPath: url.path),
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              size > 0 else { return nil }
        return url
    }

    /// Reconstructs a player snapshot from already-downloaded remote audio.
    /// This keeps a remote-backed book usable after relaunch without asking
    /// the server for a job snapshot before the listener can press Play.
    nonisolated static func localPlaybackSnapshot(jobId: String) -> JobSnapshot? {
        guard let manifest = loadManifest(for: jobId) else { return nil }
        let chapters = manifest.chapters.compactMap { entry -> JobSnapshot.Chapter? in
            guard let url = localAudioURL(jobId: jobId, chapterIndex: entry.index) else { return nil }
            return JobSnapshot.Chapter(
                index: entry.index,
                name: entry.title,
                status: "completed",
                downloadUrl: url.absoluteString,
                chars: nil,
                charsProcessed: nil,
                progressRatio: 1,
                durationSeconds: nil,
                startedAt: nil,
                completedAt: entry.downloadedAt.timeIntervalSince1970
            )
        }
        guard !chapters.isEmpty else { return nil }
        let completed = manifest.completedAt != nil
        return JobSnapshot(
            jobId: jobId,
            state: completed ? "finished" : "partial",
            bookTitle: manifest.bookTitle,
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: "remote",
            voice: "remote",
            language: nil,
            progressPercent: completed ? 100 : 0,
            chaptersTotal: max(chapters.count, manifest.chapters.count),
            chaptersCompleted: chapters.count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: manifest.completedAt?.timeIntervalSince1970
        )
    }

    nonisolated static func reusableDownloadedEntry(
        chapterIndex: Int,
        manifestEntry: AudiobookManifest.ChapterEntry?,
        fileExists: Bool
    ) -> AudiobookManifest.ChapterEntry? {
        guard let manifestEntry,
              manifestEntry.index == chapterIndex,
              manifestEntry.mp3Bytes > 0,
              fileExists else { return nil }
        return manifestEntry
    }

    nonisolated static func mergeManifests(_ old: AudiobookManifest?, _ incoming: AudiobookManifest) -> AudiobookManifest {
        guard let old else { return incoming }
        var byIndex = Dictionary(uniqueKeysWithValues: old.chapters.map { ($0.index, $0) })
        for entry in incoming.chapters { byIndex[entry.index] = entry }
        let chapters = byIndex.values.sorted { $0.index < $1.index }
        return AudiobookManifest(jobId: incoming.jobId, bookTitle: incoming.bookTitle,
                                 chapters: chapters,
                                 totalBytes: chapters.reduce(0) { $0 + $1.mp3Bytes },
                                 completedAt: incoming.completedAt ?? old.completedAt)
    }

    nonisolated static func isManifestComplete(_ manifest: AudiobookManifest, expectedChapterIndices: [Int]) -> Bool {
        let expected = Set(expectedChapterIndices)
        guard Set(manifest.chapters.map(\.index)) == expected else { return false }
        let folder = audiobookFolder(for: manifest.jobId)
        let fileManager = FileManager.default
        return manifest.chapters.allSatisfy { entry in
            let url = folder.appendingPathComponent(entry.mp3FileName)
            guard fileManager.fileExists(atPath: url.path),
                  let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? Int64 else {
                return false
            }
            return size > 0
        }
    }

    nonisolated static func saveManifest(_ manifest: AudiobookManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(for: manifest.jobId), options: .atomic)
    }

    // MARK: Public download API

    /// Enqueue every MP3 chapter from the snapshot. Returns immediately;
    /// observe progress via `watchProgress(jobId:)`.
    func enqueueAll(snapshot: JobSnapshot, baseURL: URL?) {
        cancel(jobId: snapshot.jobId)
        let chapters = snapshot.playableChapters
        guard !chapters.isEmpty else {
            emit(DownloadProgress(
                jobId: snapshot.jobId,
                chapterIndex: 0,
                totalChapters: 0,
                completedChapters: 0,
                bytesDownloaded: 0,
                bytesExpected: 0,
                state: .completed,
                lastError: nil
            ))
            return
        }
        startDownload(snapshot: snapshot, chapters: chapters, baseURL: baseURL)
    }

    func enqueueSelected(snapshot: JobSnapshot, epubZeroBasedIndices: [Int], baseURL: URL?) {
        cancel(jobId: snapshot.jobId)
        let chapters = Self.selectedChapters(snapshot: snapshot, epubZeroBasedIndices: epubZeroBasedIndices)
        guard !chapters.isEmpty else {
            emit(DownloadProgress(
                jobId: snapshot.jobId,
                chapterIndex: 0,
                totalChapters: 0,
                completedChapters: 0,
                bytesDownloaded: 0,
                bytesExpected: 0,
                state: .completed,
                lastError: nil
            ))
            return
        }
        startDownload(snapshot: snapshot, chapters: chapters, baseURL: baseURL)
    }

    private func startDownload(snapshot: JobSnapshot, chapters: [JobSnapshot.Chapter], baseURL: URL?) {
        guard storageMaintenance.isEmpty else {
            deferredDownloads[snapshot.jobId] = DeferredDownload(
                snapshot: snapshot, chapters: chapters, baseURL: baseURL)
            emit(DownloadProgress(jobId: snapshot.jobId, chapterIndex: chapters.first?.index ?? 0,
                                  totalChapters: chapters.count, completedChapters: 0,
                                  bytesDownloaded: 0, bytesExpected: 0, state: .queued, lastError: nil))
            return
        }
        let operationID = UUID()
        let predecessors = writingTasks.values.filter { $0.jobId == snapshot.jobId }.map(\.task)
        CacheActivityRegistry.begin(jobId: snapshot.jobId)
        let task = Task { [self] in
            defer {
                writingTasks.removeValue(forKey: operationID)
                if activeTasks[snapshot.jobId] == operationID {
                    activeTasks.removeValue(forKey: snapshot.jobId)
                }
                CacheActivityRegistry.end(jobId: snapshot.jobId)
            }
            // A replacement cannot write the same partial files until every
            // preceding operation for this job has relinquished ownership.
            for predecessor in predecessors { await predecessor.value }
            guard !Task.isCancelled, activeTasks[snapshot.jobId] == operationID else { return }
            await downloadSerially(snapshot: snapshot, chapters: chapters, baseURL: baseURL,
                                   operationID: operationID)
        }
        activeTasks[snapshot.jobId] = operationID
        writingTasks[operationID] = (snapshot.jobId, task)
    }

    /// Cancel an active book download without deleting completed chapters.
    func cancel(jobId: String) {
        deferredDownloads.removeValue(forKey: jobId)
        if let operationID = activeTasks[jobId] { writingTasks[operationID]?.task.cancel() }
        activeTasks.removeValue(forKey: jobId)
        let previous = lastProgress[jobId]
        emit(DownloadProgress(
            jobId: jobId,
            chapterIndex: previous?.chapterIndex ?? 0,
            totalChapters: previous?.totalChapters ?? 0,
            completedChapters: previous?.completedChapters ?? 0,
            bytesDownloaded: previous?.bytesDownloaded ?? 0,
            bytesExpected: previous?.bytesExpected ?? 0,
            state: .cancelled,
            lastError: "Download cancelled"
        ))
    }

    /// Cancel every active book download.
    func cancelAll() async {
        let retiring = writingTasks.values.map(\.task)
        for task in retiring { task.cancel() }
        // Publish cancellation before yielding so retiring callbacks cannot
        // leave observers downloading or overwrite a replacement's progress.
        for jobId in Set(activeTasks.keys).union(deferredDownloads.keys) { cancel(jobId: jobId) }
        for task in retiring { await task.value }
    }

    /// Exclude download writers for the entire storage operation. New requests
    /// remain queued until all overlapping maintenance operations have exited.
    /// The operation must not await a download held by its own maintenance lease.
    func withStorageMaintenance(_ operation: @Sendable () async throws -> Void) async throws {
        let lease = UUID()
        storageMaintenance.insert(lease)
        defer {
            storageMaintenance.remove(lease)
            if storageMaintenance.isEmpty {
                let requests = Array(deferredDownloads.values)
                deferredDownloads.removeAll()
                for request in requests {
                    startDownload(snapshot: request.snapshot, chapters: request.chapters,
                                  baseURL: request.baseURL)
                }
            }
        }
        let retiring = writingTasks.values.map(\.task)
        for task in retiring { task.cancel() }
        // Do not use cancelAll: requests queued by an overlapping maintenance
        // operation belong to the listener and must survive this cleanup.
        for jobId in Array(activeTasks.keys) { cancel(jobId: jobId) }
        for task in retiring { await task.value }
        try Task.checkCancellation()
        try await operation()
    }

    /// Cancel the active task and delete the complete offline audiobook.
    func clearDownloadedBook(jobId: String) {
        cancel(jobId: jobId)
        Self.deleteAudiobook(jobId: jobId)
    }

    nonisolated static func deleteAudiobook(jobId: String) {
        let folder = audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    nonisolated static func deleteChapter(jobId: String, chapterIndex: Int) {
        guard var manifest = loadManifest(for: jobId),
              let entry = manifest.chapters.first(where: { $0.index == chapterIndex }) else { return }
        let chapterURL = audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
            .appendingPathComponent(entry.mp3FileName)
        try? FileManager.default.removeItem(at: chapterURL)
        manifest.chapters.removeAll { $0.index == chapterIndex }
        manifest.totalBytes = max(0, manifest.totalBytes - entry.mp3Bytes)
        try? JSONEncoder().encode(manifest).write(to: manifestURL(for: jobId), options: .atomic)
    }

    /// Sequential download loop with exponential backoff.
    private func downloadSerially(
        snapshot: JobSnapshot,
        chapters: [JobSnapshot.Chapter],
        baseURL: URL?,
        operationID: UUID
    ) async {
        let total = chapters.count
        var completed = 0
        var entries: [AudiobookManifest.ChapterEntry] = []
        var totalBytes: Int64 = 0

        for chapter in chapters {
            guard activeTasks[snapshot.jobId] == operationID else { return }
            if Task.isCancelled {
                emit(DownloadProgress(
                    jobId: snapshot.jobId,
                    chapterIndex: chapter.index,
                    totalChapters: total,
                    completedChapters: completed,
                    bytesDownloaded: totalBytes,
                    bytesExpected: totalBytes,
                    state: .cancelled,
                    lastError: "Download cancelled"
                ))
                return
            }
            let previousEntry = Self.loadManifest(for: snapshot.jobId)?.chapters.first {
                $0.index == chapter.index
            }
            let previousURL = Self.localAudioURL(
                jobId: snapshot.jobId,
                chapterIndex: chapter.index
            )
            if let existing = Self.reusableDownloadedEntry(
                chapterIndex: chapter.index,
                manifestEntry: previousEntry,
                fileExists: previousURL != nil
            ) {
                entries.append(existing)
                completed += 1
                totalBytes += existing.mp3Bytes
                emit(DownloadProgress(
                    jobId: snapshot.jobId,
                    chapterIndex: chapter.index,
                    totalChapters: total,
                    completedChapters: completed,
                    bytesDownloaded: existing.mp3Bytes,
                    bytesExpected: existing.mp3Bytes,
                    state: .downloading,
                    lastError: nil
                ))
                continue
            }
            guard let path = chapter.downloadUrl,
                  let url = Self.resolve(path: path, base: baseURL) else { continue }

            emit(DownloadProgress(
                jobId: snapshot.jobId,
                chapterIndex: chapter.index,
                totalChapters: total,
                completedChapters: completed,
                bytesDownloaded: 0,
                bytesExpected: 0,
                state: .downloading,
                lastError: nil
            ))

            let safeName = Self.sanitizedFileName(chapter.name ?? "chapter_\(chapter.index)") + ".mp3"
            let dest = Self.audiobookFolder(for: snapshot.jobId).appendingPathComponent(safeName)

            do {
                let bytes = try await Self.downloadWithBackoff(url: url, to: dest)
                try Task.checkCancellation()
                guard activeTasks[snapshot.jobId] == operationID else { return }
                completed += 1
                totalBytes += bytes
                entries.append(AudiobookManifest.ChapterEntry(
                    index: chapter.index,
                    title: chapter.displayTitle,
                    mp3FileName: safeName,
                    mp3Bytes: bytes,
                    downloadedAt: Date()
                ))
                emit(DownloadProgress(
                    jobId: snapshot.jobId,
                    chapterIndex: chapter.index,
                    totalChapters: total,
                    completedChapters: completed,
                    bytesDownloaded: bytes,
                    bytesExpected: bytes,
                    state: .downloading,
                    lastError: nil
                ))
            } catch is CancellationError {
                guard activeTasks[snapshot.jobId] == operationID else { return }
                emit(DownloadProgress(
                    jobId: snapshot.jobId,
                    chapterIndex: chapter.index,
                    totalChapters: total,
                    completedChapters: completed,
                    bytesDownloaded: totalBytes,
                    bytesExpected: totalBytes,
                    state: .cancelled,
                    lastError: "Download cancelled"
                ))
                return
            } catch {
                guard !Task.isCancelled, activeTasks[snapshot.jobId] == operationID else { return }
                emit(DownloadProgress(
                    jobId: snapshot.jobId,
                    chapterIndex: chapter.index,
                    totalChapters: total,
                    completedChapters: completed,
                    bytesDownloaded: 0,
                    bytesExpected: 0,
                    state: .failed,
                    lastError: error.localizedDescription
                ))
            }
        }

        guard !Task.isCancelled, activeTasks[snapshot.jobId] == operationID else { return }
        let incoming = AudiobookManifest(
            jobId: snapshot.jobId,
            bookTitle: snapshot.bookTitle ?? snapshot.jobId,
            chapters: entries.sorted { $0.index < $1.index },
            totalBytes: totalBytes,
            completedAt: nil
        )
        let merged = Self.mergeManifests(Self.loadManifest(for: snapshot.jobId), incoming)
        let expectedIndices = snapshot.playableChapters.map(\.index)
        let complete = chapters.count == total && Self.isManifestComplete(merged, expectedChapterIndices: expectedIndices)
        try? Self.saveManifest(AudiobookManifest(
            jobId: merged.jobId, bookTitle: merged.bookTitle, chapters: merged.chapters,
            totalBytes: merged.totalBytes, completedAt: complete ? Date() : nil
        ))

        emit(DownloadProgress(
            jobId: snapshot.jobId,
            chapterIndex: chapters.last?.index ?? 0,
            totalChapters: total,
            completedChapters: completed,
            bytesDownloaded: totalBytes,
            bytesExpected: totalBytes,
            state: completed == total ? .completed : .failed,
            lastError: completed == total ? nil : "\(total - completed) chapter(s) failed"
        ))
    }

    // MARK: Network (nonisolated — stateless)

    private nonisolated static func downloadWithBackoff(url: URL, to destination: URL) async throws -> Int64 {
        let maxAttempts = 6
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            try Task.checkCancellation()
            attempt += 1
            do {
                return try await downloadOnce(url: url, to: destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
                let delaySeconds = min(30, pow(2.0, Double(attempt - 1)))
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private nonisolated static func downloadOnce(url: URL, to destination: URL) async throws -> Int64 {
        try Task.checkCancellation()
        if url.isFileURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let expectedBytes = (attributes[.size] as? Int64) ?? 0
            guard expectedBytes > 0 else { throw URLError(.cannotDecodeContentData) }
            let staged = destination.appendingPathExtension("local-partial")
            defer { try? FileManager.default.removeItem(at: staged) }
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: url, to: staged)
            return try commitDownloadedFile(
                from: staged,
                to: destination,
                expectedBytes: expectedBytes
            )
        }
        let partial = destination.appendingPathExtension("partial")
        let existingBytes = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let (tempURL, response) = try await BackgroundDownloadSession.shared.download(
            from: Self.request(url: url, resumingAt: existingBytes)
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        if existingBytes > 0, statusCode == 206 {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(contentsOf: tempURL))
            try handle.close()
            guard let expectedBytes = Self.contentRangeTotal(from: response) else {
                throw URLError(.cannotDecodeContentData)
            }
            return try commitDownloadedFile(from: partial, to: destination, expectedBytes: expectedBytes)
        }
        // A server may ignore Range and return the complete object. Never
        // append that response to an existing partial file.
        try? FileManager.default.removeItem(at: partial)
        let expectedBytes = (response as? HTTPURLResponse)?.expectedContentLength ?? 0
        return try commitDownloadedFile(from: tempURL, to: destination, expectedBytes: expectedBytes)
    }

    /// Installs only a complete staged download. A partial artifact never
    /// replaces the user-visible MP3.
    nonisolated static func commitDownloadedFile(
        from stagedFile: URL,
        to destination: URL,
        expectedBytes: Int64
    ) throws -> Int64 {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: stagedFile.path)
        let bytes = (attributes[.size] as? Int64) ?? 0
        guard bytes > 0, expectedBytes <= 0 || bytes == expectedBytes else {
            throw URLError(.cannotDecodeContentData)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: stagedFile, to: destination)
        return bytes
    }

    /// Builds the request used to resume a staged audiobook chapter.
    nonisolated static func request(url: URL, resumingAt offset: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    /// Returns the complete object size from a `Content-Range` header such as
    /// `bytes 100-199/200`.
    nonisolated static func contentRangeTotal(from response: URLResponse) -> Int64? {
        guard let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let total = value.split(separator: "/", maxSplits: 1).last.map(String.init)
        guard let total, total != "*" else { return nil }
        return Int64(total)
    }

    // MARK: Helpers (nonisolated — stateless)

    nonisolated static func resolve(path: String, base: URL?) -> URL? {
        if path.lowercased().hasPrefix("file://") { return URL(string: path) }
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        guard let base else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    nonisolated static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.isEmpty ? "chapter" : cleaned
        return String(trimmed.prefix(120))
    }
    nonisolated static func selectedChapters(
        snapshot: JobSnapshot,
        epubZeroBasedIndices: [Int]
    ) -> [JobSnapshot.Chapter] {
        let requested = Set(epubZeroBasedIndices)
        return snapshot.playableChapters.filter { requested.contains($0.index) }
    }
}

/// Delegate bridge for URLSession background downloads. iOS owns the task
/// while the app is suspended and relaunches the app to deliver callbacks.
private final class BackgroundDownloadSession: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloadSession()

    private final class Pending: @unchecked Sendable {
        let task: URLSessionDownloadTask
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var result: Result<(URL, URLResponse), Error>?

        init(task: URLSessionDownloadTask) { self.task = task }

        func install(_ continuation: CheckedContinuation<(URL, URLResponse), Error>) -> Bool {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        @discardableResult
        func finish(_ result: Result<(URL, URLResponse), Error>) -> Bool {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return false }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    private let lock = NSLock()
    private lazy var session = URLSession(
        configuration: DownloadManager.backgroundSessionConfiguration(),
        delegate: self,
        delegateQueue: nil
    )
    private var pending: [Int: Pending] = [:]

    func download(from request: URLRequest) async throws -> (URL, URLResponse) {
        let item = register(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if item.install(continuation) { item.task.resume() }
            }
        } onCancel: {
            self.cancel(item)
        }
    }

    private func register(_ request: URLRequest) -> Pending {
        lock.lock()
        defer { lock.unlock() }
        let task = session.downloadTask(with: request)
        let item = Pending(task: task)
        pending[task.taskIdentifier] = item
        return item
    }

    private func cancel(_ item: Pending) {
        lock.lock()
        pending.removeValue(forKey: item.task.taskIdentifier)
        lock.unlock()
        item.task.cancel()
        item.finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let item = pending.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let item else { return }
        // URLSession deletes its temporary file when this callback returns.
        // Transfer ownership before resuming the asynchronous consumer.
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub-download-\(UUID().uuidString).partial")
        do {
            try FileManager.default.moveItem(at: location, to: stagedURL)
            let accepted = item.finish(.success((
                stagedURL,
                downloadTask.response ?? URLResponse(
                    url: downloadTask.originalRequest?.url ?? URL(string: "about:blank")!,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                )
            )))
            if !accepted { try? FileManager.default.removeItem(at: stagedURL) }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            item.finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let item = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        item?.finish(.failure(error))
    }
}
