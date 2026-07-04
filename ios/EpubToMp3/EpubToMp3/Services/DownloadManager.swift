import Foundation

/// Per-chapter download state for `DownloadManager`.
struct DownloadProgress: Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case queued
        case downloading
        case completed
        case failed
        case paused
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

    // MARK: Public progress streams

    private var progressContinuations: [String: [UUID: AsyncStream<DownloadProgress>.Continuation]] = [:]
    private var lastProgress: [String: DownloadProgress] = [:]

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

    nonisolated static func audiobooksRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(audiobooksFolderName, isDirectory: true)
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

    nonisolated static func saveManifest(_ manifest: AudiobookManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(for: manifest.jobId), options: .atomic)
    }

    // MARK: Public download API

    /// Enqueue every MP3 chapter from the snapshot. Returns immediately;
    /// observe progress via `watchProgress(jobId:)`.
    func enqueueAll(snapshot: JobSnapshot, baseURL: URL?) {
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
        Task { [weak self] in
            await self?.downloadSerially(snapshot: snapshot, chapters: chapters, baseURL: baseURL)
        }
    }

    func enqueueSelected(snapshot: JobSnapshot, epubZeroBasedIndices: [Int], baseURL: URL?) {
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
        Task { [weak self] in
            await self?.downloadSerially(snapshot: snapshot, chapters: chapters, baseURL: baseURL)
        }
    }

    /// Sequential download loop with exponential backoff.
    private func downloadSerially(
        snapshot: JobSnapshot,
        chapters: [JobSnapshot.Chapter],
        baseURL: URL?
    ) async {
        let total = chapters.count
        var completed = 0
        var entries: [AudiobookManifest.ChapterEntry] = []
        var totalBytes: Int64 = 0

        for chapter in chapters {
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

        let manifest = AudiobookManifest(
            jobId: snapshot.jobId,
            bookTitle: snapshot.bookTitle ?? snapshot.jobId,
            chapters: entries.sorted { $0.index < $1.index },
            totalBytes: totalBytes,
            completedAt: completed == total ? Date() : nil
        )
        try? Self.saveManifest(manifest)

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
            attempt += 1
            do {
                return try await downloadOnce(url: url, to: destination)
            } catch {
                lastError = error
                let delaySeconds = min(30, pow(2.0, Double(attempt - 1)))
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private nonisolated static func downloadOnce(url: URL, to destination: URL) async throws -> Int64 {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        let (tempURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        return (attrs[.size] as? Int64) ?? 0
    }

    // MARK: Helpers (nonisolated — stateless)

    nonisolated static func resolve(path: String, base: URL?) -> URL? {
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
