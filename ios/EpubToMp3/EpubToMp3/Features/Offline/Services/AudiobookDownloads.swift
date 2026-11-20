import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Runs the listener's Download requests: it keeps each requested chapter in
/// `LocalAudioArtifactStore` under the book that owns the snapshot, reports
/// progress per job and excludes its writers from storage maintenance.
///
/// Audio kept by the previous `Audiobooks/<jobId>` layout is only read and
/// removed here; nothing new is written there.
actor AudiobookDownloads {
    typealias OwnerResolver = @Sendable (JobSnapshot) async -> RetainedAudioOwner?

    enum DownloadError: LocalizedError {
        /// No record names the book this snapshot's audio belongs to.
        case unknownBook

        var errorDescription: String? { L10n.string("error.localAudioMissing") }
    }

    static let shared = AudiobookDownloads()

    private let store: LocalAudioArtifactStore
    private let resolveOwner: OwnerResolver
    private let stopLegacyMigration: @Sendable () async -> Void

    init(store: LocalAudioArtifactStore = .shared,
         resolveOwner: @escaping OwnerResolver = { await RetainedAudioOwner.resolve($0) },
         stopLegacyMigration: @escaping @Sendable () async -> Void = {
             await LegacyAudioMigrationSession.shared.stop()
         }) {
        self.store = store
        self.resolveOwner = resolveOwner
        self.stopLegacyMigration = stopLegacyMigration
    }

    /// Every removal of kept audio calls this first: a migration still copying
    /// legacy audio into the store could otherwise bring the removed audio back.
    func quiesceLegacyMigration() async {
        await stopLegacyMigration()
    }

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
    private var bookStorageMaintenance: [UUID: String] = [:]
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
        guard storageMaintenance.isEmpty, !bookStorageMaintenance.values.contains(snapshot.jobId) else {
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
        await stopLegacyMigration()
        let retiring = writingTasks.values.map(\.task)
        for task in retiring { task.cancel() }
        // Do not use cancelAll: requests queued by an overlapping maintenance
        // operation belong to the listener and must survive this cleanup.
        for jobId in Array(activeTasks.keys) { cancel(jobId: jobId) }
        for task in retiring { await task.value }
        try Task.checkCancellation()
        try await operation()
    }

    /// Wait for this job's writers without cancelling another book's download.
    func withBookStorageMaintenance(jobId: String,
                                    operation: @Sendable () async throws -> Void) async throws {
        let lease = UUID()
        bookStorageMaintenance[lease] = jobId
        defer {
            bookStorageMaintenance.removeValue(forKey: lease)
            if storageMaintenance.isEmpty, !bookStorageMaintenance.values.contains(jobId),
               let request = deferredDownloads.removeValue(forKey: jobId) {
                startDownload(snapshot: request.snapshot, chapters: request.chapters, baseURL: request.baseURL)
            }
        }
        await stopLegacyMigration()
        let retiring = writingTasks.values.filter { $0.jobId == jobId }.map(\.task)
        for task in retiring { task.cancel() }
        cancel(jobId: jobId)
        for task in retiring { await task.value }
        try Task.checkCancellation()
        try await operation()
    }

    /// Cancel the active task and delete the job's audio in the previous layout.
    func clearDownloadedBook(jobId: String) {
        cancel(jobId: jobId)
        AudiobookDownloadStorage.deleteAudiobook(jobId: jobId)
    }

    // MARK: Kept audio of one snapshot

    /// Snapshot chapter indices whose audio is kept on this device: protected
    /// chapters of the snapshot's book, plus audio still in the previous layout.
    func downloadedIndices(for snapshot: JobSnapshot) async -> Set<Int> {
        var indices = AudiobookDownloadStorage.locallyDownloadedIndices(for: snapshot.jobId)
        if let owner = await resolveOwner(snapshot),
           let kept = try? await store.downloadedChapterIndices(bookID: owner.bookID) {
            indices.formUnion(kept.map(owner.snapshotIndex(forStoreIndex:)))
        }
        return indices
    }

    /// Ends the Download of one chapter in both layouts.
    func removeDownload(snapshot: JobSnapshot, chapterIndex: Int) async {
        await stopLegacyMigration()
        if let owner = await resolveOwner(snapshot) {
            await release(owner: owner, snapshot: snapshot, chapterIndices: [chapterIndex])
        }
        AudiobookDownloadStorage.deleteChapter(jobId: snapshot.jobId, chapterIndex: chapterIndex)
        NotificationCenter.default.post(name: LocalAudioArtifactStore.didChangeNotification, object: nil)
    }

    /// Cancels the active Download and ends the Downloads of the chapters this
    /// snapshot plays. Kept audio of chapters the snapshot does not have is
    /// another job's and is never touched from here.
    func clearDownloads(snapshot: JobSnapshot) async {
        await stopLegacyMigration()
        cancel(jobId: snapshot.jobId)
        let retiring = writingTasks.values.filter { $0.jobId == snapshot.jobId }.map(\.task)
        for task in retiring { await task.value }
        if let owner = await resolveOwner(snapshot) {
            await release(owner: owner, snapshot: snapshot,
                          chapterIndices: snapshot.playableChapters.map(\.index))
        }
        AudiobookDownloadStorage.deleteAudiobook(jobId: snapshot.jobId)
        NotificationCenter.default.post(name: LocalAudioArtifactStore.didChangeNotification, object: nil)
    }

    private func release(owner: RetainedAudioOwner, snapshot: JobSnapshot, chapterIndices: [Int]) async {
        for chapterIndex in chapterIndices {
            guard let storeIndex = owner.storeIndex(forSnapshotIndex: chapterIndex),
                  let chapter = snapshot.playableChapters.first(where: { $0.index == chapterIndex }) else { continue }
            let source = chapter.downloadUrl.flatMap { AudiobookChapterTransfer.resolve(path: $0, base: nil) }
            // Like the previous layout, a removal that fails leaves the chapter kept.
            _ = try? await store.releaseDownload(
                bookID: owner.bookID, chapterIndex: storeIndex, playbackSource: source,
                sourceTextOffset: chapter.textOffset ?? 0)
        }
    }

    /// Keeps the requested chapters one at a time.
    private func downloadSerially(
        snapshot: JobSnapshot,
        chapters: [JobSnapshot.Chapter],
        baseURL: URL?,
        operationID: UUID
    ) async {
        let total = chapters.count
        var completed = 0
        var totalBytes: Int64 = 0
        let owner = await resolveOwner(snapshot)
        // Audio the previous layout already keeps stays there until it is migrated.
        let keptByPreviousLayout = AudiobookDownloadStorage.locallyDownloadedIndices(for: snapshot.jobId)

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
            if keptByPreviousLayout.contains(chapter.index) {
                let bytes = AudiobookDownloadStorage.loadManifest(for: snapshot.jobId)?.chapters
                    .first { $0.index == chapter.index }?.mp3Bytes ?? 0
                completed += 1
                totalBytes += bytes
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

            do {
                guard let owner, let storeIndex = owner.storeIndex(forSnapshotIndex: chapter.index) else {
                    throw DownloadError.unknownBook
                }
                let request = LocalAudioArtifactStore.DownloadRequest(
                    bookID: owner.bookID, bookTitle: snapshot.bookTitle ?? snapshot.jobId,
                    author: snapshot.bookAuthor, chapterIndex: storeIndex, chapterTitle: chapter.displayTitle,
                    textOffset: max(0, chapter.textOffset ?? 0))
                let bytes = try await keep(url, request: request, operationID: operationID)
                try Task.checkCancellation()
                guard activeTasks[snapshot.jobId] == operationID else { return }
                completed += 1
                totalBytes += bytes
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

    /// A local file is kept directly. A remote one is fetched to a private
    /// staging file first, so the store only ever receives complete audio.
    private func keep(
        _ url: URL, request: LocalAudioArtifactStore.DownloadRequest, operationID: UUID
    ) async throws -> Int64 {
        guard !url.isFileURL else { return try await store.retainDownload(from: url, request: request) }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(operationID.uuidString)-\(request.chapterIndex).mp3")
        defer { try? FileManager.default.removeItem(at: staged) }
        _ = try await AudiobookChapterTransfer.downloadWithBackoff(url: url, to: staged)
        try Task.checkCancellation()
        return try await store.retainDownload(from: staged, request: request)
    }

    nonisolated static func selectedChapters(
        snapshot: JobSnapshot,
        epubZeroBasedIndices: [Int]
    ) -> [JobSnapshot.Chapter] {
        let requested = Set(epubZeroBasedIndices)
        return snapshot.playableChapters.filter { requested.contains($0.index) }
    }
}
