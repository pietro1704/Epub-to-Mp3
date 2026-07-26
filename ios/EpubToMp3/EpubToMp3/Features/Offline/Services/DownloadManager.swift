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
    private var activeTasks: [String: Task<Void, Never>] = [:]

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

    nonisolated static func audiobooksRoot() -> URL {
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
        let folder = audiobookFolder(for: jobId)
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
        CacheActivityRegistry.begin(jobId: snapshot.jobId)
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.downloadSerially(snapshot: snapshot, chapters: chapters, baseURL: baseURL)
        }
        activeTasks[snapshot.jobId] = task
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
        CacheActivityRegistry.begin(jobId: snapshot.jobId)
        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.downloadSerially(snapshot: snapshot, chapters: chapters, baseURL: baseURL)
        }
        activeTasks[snapshot.jobId] = task
    }

    /// Cancel an active book download without deleting completed chapters.
    func cancel(jobId: String) {
        activeTasks[jobId]?.cancel()
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
    func cancelAll() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
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

    /// Sequential download loop with exponential backoff.
    private func downloadSerially(
        snapshot: JobSnapshot,
        chapters: [JobSnapshot.Chapter],
        baseURL: URL?
    ) async {
        defer { CacheActivityRegistry.end(jobId: snapshot.jobId) }
        let total = chapters.count
        var completed = 0
        var entries: [AudiobookManifest.ChapterEntry] = []
        var totalBytes: Int64 = 0

        for chapter in chapters {
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

        // After each completed download, run LRU+TTL eviction in the background.
        // Exclude the job we just downloaded so it is never immediately evicted.
        let newJobId = snapshot.jobId
        Task.detached(priority: .background) {
            AudiobookCacheEviction.runEviction(activeJobIds: [newJobId])
        }

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
            } catch {
                lastError = error
                let delaySeconds = min(30, pow(2.0, Double(attempt - 1)))
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private nonisolated static func downloadOnce(url: URL, to destination: URL) async throws -> Int64 {
        if url.isFileURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let expectedBytes = (attributes[.size] as? Int64) ?? 0
            guard expectedBytes > 0 else { throw URLError(.cannotDecodeContentData) }
            let staged = destination.appendingPathExtension("local-partial")
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: url, to: staged)
            return try commitDownloadedFile(
                from: staged,
                to: destination,
                expectedBytes: expectedBytes
            )
        }
        let (tempURL, response) = try await BackgroundDownloadSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
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

    private struct Pending {
        let continuation: CheckedContinuation<(URL, URLResponse), Error>
    }

    private let lock = NSLock()
    private lazy var session = URLSession(
        configuration: DownloadManager.backgroundSessionConfiguration(),
        delegate: self,
        delegateQueue: nil
    )
    private var pending: [Int: Pending] = [:]

    func download(from url: URL) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            lock.lock()
            pending[task.taskIdentifier] = Pending(continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let item = pending.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        item?.continuation.resume(returning: (
            location,
            downloadTask.response ?? URLResponse(
                url: downloadTask.originalRequest?.url ?? URL(string: "about:blank")!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            )
        ))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        lock.lock()
        let item = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        item?.continuation.resume(throwing: error)
    }
}
