import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Background-aware MP3 download manager.
///
/// Actor isolation replaces the manual `NSLock` that previously guarded
/// `progressContinuations` and `lastProgress`. All mutable state is now
/// compile-time checked for data-race safety.
actor AudiobookDownloads {

    static let shared = AudiobookDownloads()

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
        AudiobookDownloadStorage.deleteAudiobook(jobId: jobId)
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
            let previousEntry = AudiobookDownloadStorage.loadManifest(for: snapshot.jobId)?.chapters.first {
                $0.index == chapter.index
            }
            let previousURL = AudiobookDownloadStorage.localAudioURL(
                jobId: snapshot.jobId,
                chapterIndex: chapter.index
            )
            if let existing = AudiobookDownloadStorage.reusableDownloadedEntry(
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
                  let url = AudiobookChapterTransfer.resolve(path: path, base: baseURL) else { continue }

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

            let safeName = AudiobookChapterTransfer.sanitizedFileName(chapter.name ?? "chapter_\(chapter.index)") + ".mp3"
            let dest = AudiobookDownloadStorage.audiobookFolder(for: snapshot.jobId).appendingPathComponent(safeName)

            do {
                let bytes = try await AudiobookChapterTransfer.downloadWithBackoff(url: url, to: dest)
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
        let merged = AudiobookDownloadStorage.mergeManifests(AudiobookDownloadStorage.loadManifest(for: snapshot.jobId), incoming)
        let expectedIndices = snapshot.playableChapters.map(\.index)
        let complete = chapters.count == total && AudiobookDownloadStorage.isManifestComplete(merged, expectedChapterIndices: expectedIndices)
        try? AudiobookDownloadStorage.saveManifest(AudiobookManifest(
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

    nonisolated static func selectedChapters(
        snapshot: JobSnapshot,
        epubZeroBasedIndices: [Int]
    ) -> [JobSnapshot.Chapter] {
        let requested = Set(epubZeroBasedIndices)
        return snapshot.playableChapters.filter { requested.contains($0.index) }
    }
}
