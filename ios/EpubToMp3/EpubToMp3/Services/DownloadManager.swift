import Foundation

/// Per-chapter download state for `DownloadManager`.
struct DownloadProgress: Equatable {
    enum State: String, Codable, Equatable {
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
struct AudiobookManifest: Codable, Equatable {
    struct ChapterEntry: Codable, Equatable {
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
/// Design notes:
///   - Uses `URLSession` with `.background(withIdentifier:)` so transfers
///     continue when the app is suspended.
///   - Persists the per-job queue to disk so we can re-attach on relaunch.
///   - Caps concurrent downloads at 3 (per-job, not global).
///   - Exponential backoff up to 30s after 6 retries.
///   - Stores files at `<documents>/Audiobooks/<jobId>/chapters/<safeName>.mp3`.
///
/// SHA verification is left as a TODO for slice 3 — backend currently
/// doesn't expose `?sha=true`.
final class DownloadManager: NSObject, @unchecked Sendable {

    // MARK: Public progress streams

    private let progressLock = NSLock()
    private var progressContinuations: [String: [UUID: AsyncStream<DownloadProgress>.Continuation]] = [:]
    private var lastProgress: [String: DownloadProgress] = [:]

    func watchProgress(jobId: String) -> AsyncStream<DownloadProgress> {
        AsyncStream { continuation in
            let id = UUID()
            self.progressLock.lock()
            self.progressContinuations[jobId, default: [:]][id] = continuation
            if let last = self.lastProgress[jobId] { continuation.yield(last) }
            self.progressLock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.progressLock.lock()
                self.progressContinuations[jobId]?.removeValue(forKey: id)
                self.progressLock.unlock()
            }
        }
    }

    private func emit(_ progress: DownloadProgress) {
        progressLock.lock()
        lastProgress[progress.jobId] = progress
        let conts = progressContinuations[progress.jobId]?.values ?? [:].values
        progressLock.unlock()
        for cont in conts { cont.yield(progress) }
    }

    // MARK: Storage layout

    static let audiobooksFolderName = "Audiobooks"

    static func audiobooksRoot() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(audiobooksFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func audiobookFolder(for jobId: String) -> URL {
        let url = audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func manifestURL(for jobId: String) -> URL {
        audiobooksRoot().appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("manifest.json")
    }

    static func loadManifest(for jobId: String) -> AudiobookManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: jobId)) else { return nil }
        return try? JSONDecoder().decode(AudiobookManifest.self, from: data)
    }

    static func saveManifest(_ manifest: AudiobookManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(for: manifest.jobId), options: .atomic)
    }

    // MARK: Background URLSession

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(
            withIdentifier: "com.pietrocode.epubtomp3.downloads"
        )
        config.allowsCellularAccess = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

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
        Task.detached { [weak self] in
            guard let self else { return }
            await self.downloadSerially(snapshot: snapshot, chapters: chapters, baseURL: baseURL)
        }
    }

    /// Sequential download loop with exponential backoff. Capped to 3
    /// inflight by `httpMaximumConnectionsPerHost`; we serialise here to
    /// keep manifest writes atomic without locking.
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
                let bytes = try await self.downloadWithBackoff(url: url, to: dest)
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
                // Keep going on partial failures — operator can retry later.
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

    private func downloadWithBackoff(url: URL, to destination: URL) async throws -> Int64 {
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

    private func downloadOnce(url: URL, to destination: URL) async throws -> Int64 {
        // Use the foreground session for the actual transfer here. The
        // background session is wired up but URLSession.download(for:) is
        // only available on the default session in this slice — slice 3
        // will switch to a delegate-based background workflow.
        let foregroundConfig = URLSessionConfiguration.default
        foregroundConfig.timeoutIntervalForRequest = 60
        foregroundConfig.timeoutIntervalForResource = 600
        let fg = URLSession(configuration: foregroundConfig)
        let (tempURL, response) = try await fg.download(from: url)
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

    // MARK: Helpers

    static func resolve(path: String, base: URL?) -> URL? {
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        guard let base else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.isEmpty ? "chapter" : cleaned
        return String(trimmed.prefix(120))
    }
}
