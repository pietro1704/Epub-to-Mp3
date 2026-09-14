#if os(macOS)
import Foundation
import Network
import XCTest
@testable import EpubToMp3

private final class DelayedDownloadHTTPServer: @unchecked Sendable {
    let ready = XCTestExpectation(description: "Loopback listener ready")
    let received = XCTestExpectation(description: "Actual download GET received")
    let sent = XCTestExpectation(description: "HTTP response send finished")
    private let queue = DispatchQueue(label: "DownloadCleanupHTTP")
    private let listener: NWListener
    private let lock = NSLock()
    private var boundPort: UInt16?
    private var didReceiveRequest = false
    private var connection: NWConnection?
    private var request = Data()
    private var released = false
    private var responded = false
    private let bytes: Data

    init(bytes: Data) throws {
        self.bytes = bytes
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.lock.lock()
                self.boundPort = self.listener.port?.rawValue
                self.lock.unlock()
                self.ready.fulfill()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connection == nil else { connection.cancel(); return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.receive(connection)
        }
        listener.start(queue: queue)
    }

    var url: URL? {
        lock.lock(); defer { lock.unlock() }
        return boundPort.flatMap { URL(string: "http://127.0.0.1:\($0)/chapter.mp3") }
    }

    var hasReceivedRequest: Bool {
        lock.lock(); defer { lock.unlock() }
        return didReceiveRequest
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.request.append(data) }
            if self.request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.lock.lock()
                self.didReceiveRequest = true
                self.lock.unlock()
                XCTAssertTrue(String(decoding: self.request, as: UTF8.self).hasPrefix("GET /chapter.mp3 "))
                self.received.fulfill()
                self.respondIfReleased()
            } else if !complete && error == nil {
                self.receive(connection)
            }
        }
    }

    func releaseResponse() {
        queue.async { self.released = true; self.respondIfReleased() }
    }

    private func respondIfReleased() {
        guard released, !responded, let connection,
              request.range(of: Data("\r\n\r\n".utf8)) != nil else { return }
        responded = true
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(bytes)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.sent.fulfill()
            connection.cancel()
        })
    }

    func close() {
        queue.async { self.connection?.cancel(); self.listener.cancel() }
    }
}

private actor CleanupDownloadProgress {
    private(set) var states: [DownloadProgress.State] = []
    func append(_ state: DownloadProgress.State) { states.append(state) }
}

private actor CleanupOperationCompletion {
    private(set) var finished = false
    func finish() { finished = true }
}

private actor DownloadMaintenanceGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    let entered = XCTestExpectation(description: "Cleanup cancellation finished; deletion still gated")
    func wait() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class DownloadManagerCleanupRaceTests: XCTestCase {
    private enum AdmissionScenario {
        case normal, overlap, failure, callerCancellation, cancelJob, cancelAll, replacement
    }

    func testDownloadRequestedDuringCleanupWaitsUntilDeletionFinishes() async throws {
        try await exerciseAdmission(.normal)
    }

    func testOverlappingMaintenanceKeepsDownloadQueuedUntilLastLeaseEnds() async throws {
        try await exerciseAdmission(.overlap)
    }

    func testFailedFilesystemMaintenanceReleasesIndependentDownload() async throws {
        try await exerciseAdmission(.failure)
    }

    func testCancelledMaintenanceCallerReleasesIndependentDownload() async throws {
        try await exerciseAdmission(.callerCancellation)
    }

    func testCancelJobRemovesDownloadDeferredByMaintenance() async throws {
        try await exerciseAdmission(.cancelJob)
    }

    func testCancelAllRemovesDownloadDeferredByMaintenance() async throws {
        try await exerciseAdmission(.cancelAll)
    }

    func testDeferredReplacementDownloadsOnlyLatestRequest() async throws {
        try await exerciseAdmission(.replacement)
    }

    private func exerciseAdmission(_ scenario: AdmissionScenario) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadMaintenanceAdmission-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        let jobID = UUID().uuidString
        let chapterURL = downloads.appendingPathComponent("\(jobID)/chapters/Fixture.mp3")
        let manifestURL = downloads.appendingPathComponent("\(jobID)/manifest.json")
        let previousRoot = DownloadManager.rootOverrideForTesting
        DownloadManager.rootOverrideForTesting = downloads
        let manager = DownloadManager()
        let gate = DownloadMaintenanceGate()
        let bytes = Data(repeating: 0x4D, count: 4096)
        let server = try DelayedDownloadHTTPServer(bytes: bytes)
        let replacementBytes = Data(repeating: 0x2F, count: 2048)
        let replacementServer = scenario == .replacement
            ? try DelayedDownloadHTTPServer(bytes: replacementBytes) : nil
        let completion = CleanupOperationCompletion()
        let secondCompletion = CleanupOperationCompletion()
        let secondGate = DownloadMaintenanceGate()
        var ttsRoot = root.appendingPathComponent("tts")
        if scenario == .failure {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let blocker = root.appendingPathComponent("not-a-directory")
            try Data([1]).write(to: blocker)
            ttsRoot = blocker.appendingPathComponent("tts")
            do {
                try FileManager.default.removeItem(at: ttsRoot)
                XCTFail("The filesystem failure fixture must refuse traversal through a regular file")
            } catch {
                XCTAssertNotEqual((error as NSError).code, NSFileNoSuchFileError)
            }
        }
        let service = AudioStorageMaintenance(
            artifactStore: LocalAudioArtifactStore(root: root.appendingPathComponent("artifacts")),
            legacyAudiobooksRoot: downloads, legacyTTSRoot: ttsRoot,
            downloadManager: manager, cancelDownloads: { await gate.wait() },
            notificationCenter: NotificationCenter())
        let cleanup = Task {
            do {
                try await service.clearAllDownloads()
                await completion.finish()
            } catch {
                await completion.finish()
                throw error
            }
        }
        addTeardownBlock {
            await gate.release()
            await secondGate.release()
            server.releaseResponse()
            server.close()
            replacementServer?.releaseResponse()
            replacementServer?.close()
            let drained = CleanupOperationCompletion()
            let cancel = Task { await manager.cancelAll(); await drained.finish() }
            for _ in 0..<400 {
                if await completion.finished, await secondCompletion.finished, await drained.finished,
                   !CacheActivityRegistry.activeJobIds().contains(jobID) { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            guard await completion.finished, await secondCompletion.finished, await drained.finished,
                  !CacheActivityRegistry.activeJobIds().contains(jobID) else {
                cleanup.cancel(); cancel.cancel()
                XCTFail("Keep the isolated root until cleanup and writers quiesce")
                return
            }
            DownloadManager.rootOverrideForTesting = previousRoot
            try? FileManager.default.removeItem(at: root)
        }
        if scenario != .overlap { await secondCompletion.finish() }
        await fulfillment(of: [server.ready, gate.entered], timeout: 5)
        let url = try XCTUnwrap(server.url)
        let snapshot = JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Fixture",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "remote", voice: nil,
            language: "en", progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [.init(index: 0, name: "Fixture", status: "completed",
                downloadUrl: url.absoluteString, chars: nil, charsProcessed: nil, progressRatio: 1,
                durationSeconds: nil, startedAt: nil, completedAt: nil)],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        await manager.enqueueAll(snapshot: snapshot, baseURL: nil)
        var secondCleanup: Task<Void, Error>?
        if scenario == .overlap {
            secondCleanup = Task {
                do {
                    try await manager.withStorageMaintenance { await secondGate.wait() }
                    await secondCompletion.finish()
                } catch {
                    await secondCompletion.finish()
                    throw error
                }
            }
            await fulfillment(of: [secondGate.entered], timeout: 5)
        }
        if let replacementServer {
            await fulfillment(of: [replacementServer.ready], timeout: 5)
            let replacementURL = try XCTUnwrap(replacementServer.url)
            let replacement = JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Replacement",
                bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "remote", voice: nil,
                language: "en", progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
                chapterProgress: [.init(index: 0, name: "Fixture", status: "completed",
                    downloadUrl: replacementURL.absoluteString, chars: nil, charsProcessed: nil, progressRatio: 1,
                    durationSeconds: nil, startedAt: nil, completedAt: nil)],
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
            await manager.enqueueAll(snapshot: replacement, baseURL: nil)
        }
        // Keep deletion gated while allowing actor/network scheduling to run.
        try await Task.sleep(nanoseconds: 300_000_000)
        let waitingStream = await manager.watchProgress(jobId: jobID)
        var waitingIterator = waitingStream.makeAsyncIterator()
        let waiting = await waitingIterator.next()
        XCTAssertEqual(waiting?.state, .queued)
        XCTAssertFalse(server.hasReceivedRequest, "A new download must not start HTTP before deletion finishes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: chapterURL.path))
        if scenario == .cancelJob { await manager.cancel(jobId: jobID) }
        if scenario == .cancelAll { await manager.cancelAll() }
        if scenario == .callerCancellation { cleanup.cancel() }
        await gate.release()
        for _ in 0..<200 {
            if await completion.finished { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard await completion.finished else {
            server.releaseResponse()
            XCTFail("Cleanup did not finish after its gate was released")
            throw NSError(domain: "DownloadMaintenanceAdmission", code: 1)
        }
        do {
            try await cleanup.value
            if scenario == .failure || scenario == .callerCancellation {
                XCTFail("Maintenance must report its failure instead of manufacturing success")
            }
        } catch {
            if scenario == .callerCancellation {
                XCTAssertTrue(error is CancellationError)
            } else if scenario == .failure {
                XCTAssertFalse(error is CancellationError)
            } else { throw error }
        }
        if let secondCleanup {
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(server.hasReceivedRequest, "Ending one lease must not open the other lease's gate")
            let heldStream = await manager.watchProgress(jobId: jobID)
            var heldIterator = heldStream.makeAsyncIterator()
            let held = await heldIterator.next()
            XCTAssertEqual(held?.state, .queued)
            await secondGate.release()
            for _ in 0..<200 {
                if await secondCompletion.finished { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            guard await secondCompletion.finished else {
                secondCleanup.cancel()
                throw NSError(domain: "DownloadMaintenanceAdmission", code: 2)
            }
            try await secondCleanup.value
        }
        if scenario == .cancelJob || scenario == .cancelAll {
            try await Task.sleep(nanoseconds: 300_000_000)
            let cancelledStream = await manager.watchProgress(jobId: jobID)
            var cancelledIterator = cancelledStream.makeAsyncIterator()
            let cancelled = await cancelledIterator.next()
            XCTAssertEqual(cancelled?.state, .cancelled)
            XCTAssertFalse(server.hasReceivedRequest)
            XCTAssertFalse(CacheActivityRegistry.activeJobIds().contains(jobID))
            XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
            return
        }
        let acceptedServer = replacementServer ?? server
        let acceptedBytes = replacementServer == nil ? bytes : replacementBytes
        await fulfillment(of: [acceptedServer.received], timeout: 5)
        acceptedServer.releaseResponse()
        await fulfillment(of: [acceptedServer.sent], timeout: 5)
        for _ in 0..<400 {
            if !CacheActivityRegistry.activeJobIds().contains(jobID) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(CacheActivityRegistry.activeJobIds().contains(jobID))
        let finishedStream = await manager.watchProgress(jobId: jobID)
        var finishedIterator = finishedStream.makeAsyncIterator()
        let finished = await finishedIterator.next()
        XCTAssertEqual(finished?.state, .completed)
        XCTAssertEqual(try Data(contentsOf: chapterURL), acceptedBytes)
        let manifest = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.chapters.map(\.index), [0])
        XCTAssertEqual(manifest.totalBytes, Int64(acceptedBytes.count))
        if replacementServer != nil {
            XCTAssertFalse(server.hasReceivedRequest, "The replaced deferred request must never start")
            XCTAssertEqual(manifest.bookTitle, "Replacement")
        }
    }

    func testActualHTTPDownloadPositiveControlPersistsBytesAndManifest() async throws {
        try await exerciseDownload(clearWhileResponseIsPending: false)
    }

    func testClearAllDownloadsCannotBeUndoneByDelayedHTTPCompletion() async throws {
        try await exerciseDownload(clearWhileResponseIsPending: true)
    }

    private func exerciseDownload(clearWhileResponseIsPending: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadCleanupRace-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        let jobID = UUID().uuidString
        let bookRoot = downloads.appendingPathComponent(jobID, isDirectory: true)
        let manifestURL = bookRoot.appendingPathComponent("manifest.json")
        let chapterURL = bookRoot.appendingPathComponent("chapters/Fixture.mp3")
        let previousRoot = DownloadManager.rootOverrideForTesting
        DownloadManager.rootOverrideForTesting = downloads
        let manager = DownloadManager()
        let bytes = Data(repeating: 0x5A, count: 8192)
        let server = try DelayedDownloadHTTPServer(bytes: bytes)
        let progress = CleanupDownloadProgress()
        let stream = await manager.watchProgress(jobId: jobID)
        let watcher = Task {
            for await value in stream { await progress.append(value.state) }
        }
        addTeardownBlock {
            server.releaseResponse()
            server.close()
            let cancellationFinished = CleanupOperationCompletion()
            let cancellation = Task {
                await manager.cancelAll()
                await cancellationFinished.finish()
            }
            for _ in 0..<200 {
                if !CacheActivityRegistry.activeJobIds().contains(jobID),
                   await cancellationFinished.finished { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            watcher.cancel()
            guard !CacheActivityRegistry.activeJobIds().contains(jobID),
                  await cancellationFinished.finished else {
                cancellation.cancel()
                XCTFail("Writer did not quiesce; keep its isolated root override instead of redirecting late writes")
                return
            }
            DownloadManager.rootOverrideForTesting = previousRoot
            try? FileManager.default.removeItem(at: root)
        }
        await fulfillment(of: [server.ready], timeout: 5)
        let url = try XCTUnwrap(server.url)
        let snapshot = JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Fixture",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "remote", voice: nil,
            language: "en", progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [.init(index: 0, name: "Fixture", status: "completed",
                downloadUrl: url.absoluteString, chars: nil, charsProcessed: nil, progressRatio: 1,
                durationSeconds: nil, startedAt: nil, completedAt: nil)],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        await manager.enqueueAll(snapshot: snapshot, baseURL: nil)
        await fulfillment(of: [server.received], timeout: 5)
        XCTAssertTrue(CacheActivityRegistry.activeJobIds().contains(jobID))
        if clearWhileResponseIsPending {
            let service = AudioStorageMaintenance(
                artifactStore: LocalAudioArtifactStore(root: root.appendingPathComponent("artifacts")),
                legacyAudiobooksRoot: downloads, legacyTTSRoot: root.appendingPathComponent("tts"),
                downloadManager: manager, notificationCenter: NotificationCenter())
            let completion = CleanupOperationCompletion()
            let cleanup = Task {
                do {
                    try await service.clearAllDownloads()
                    await completion.finish()
                } catch {
                    await completion.finish()
                    throw error
                }
            }
            for _ in 0..<200 {
                if await completion.finished { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            if !(await completion.finished) {
                XCTFail("Cleanup must cancel and drain the pending HTTP request without waiting for its response")
                server.releaseResponse()
                for _ in 0..<400 {
                    if await completion.finished { break }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
            }
            guard await completion.finished else {
                cleanup.cancel()
                throw NSError(domain: "DownloadCleanupRace", code: 1)
            }
            try await cleanup.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
        }
        server.releaseResponse()
        await fulfillment(of: [server.sent], timeout: 5)
        for _ in 0..<400 {
            if !CacheActivityRegistry.activeJobIds().contains(jobID) { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertFalse(CacheActivityRegistry.activeJobIds().contains(jobID), "The actual download worker must finish")
        // Drain the actor's published terminal state without invoking path-creating storage helpers.
        let finalStream = await manager.watchProgress(jobId: jobID)
        var iterator = finalStream.makeAsyncIterator()
        let terminal = await iterator.next()
        let states = await progress.states
        if clearWhileResponseIsPending {
            XCTAssertFalse(FileManager.default.fileExists(atPath: chapterURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
            XCTAssertEqual(terminal?.state, .cancelled,
                           "Cleanup must publish a terminal state, not leave observers downloading")
            XCTAssertFalse(states.contains(.completed))
            // A cancellation fence must not permanently disable this manager or job.
            let freshBytes = Data(repeating: 0x3C, count: 4096)
            let freshServer = try DelayedDownloadHTTPServer(bytes: freshBytes)
            defer { freshServer.releaseResponse(); freshServer.close() }
            await fulfillment(of: [freshServer.ready], timeout: 5)
            let freshURL = try XCTUnwrap(freshServer.url)
            let freshSnapshot = JobSnapshot(jobId: jobID, state: "finished", bookTitle: "Fixture",
                bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "remote", voice: nil,
                language: "en", progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
                chapterProgress: [.init(index: 0, name: "Fixture", status: "completed",
                    downloadUrl: freshURL.absoluteString, chars: nil, charsProcessed: nil, progressRatio: 1,
                    durationSeconds: nil, startedAt: nil, completedAt: nil)],
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
            await manager.enqueueAll(snapshot: freshSnapshot, baseURL: nil)
            await fulfillment(of: [freshServer.received], timeout: 5)
            freshServer.releaseResponse()
            await fulfillment(of: [freshServer.sent], timeout: 5)
            for _ in 0..<400 {
                if !CacheActivityRegistry.activeJobIds().contains(jobID) { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertFalse(CacheActivityRegistry.activeJobIds().contains(jobID))
            let freshStream = await manager.watchProgress(jobId: jobID)
            var freshIterator = freshStream.makeAsyncIterator()
            let freshTerminal = await freshIterator.next()
            XCTAssertEqual(freshTerminal?.state, .completed)
            XCTAssertEqual(try Data(contentsOf: chapterURL), freshBytes)
            let manifest = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: manifestURL))
            XCTAssertEqual(manifest.chapters.map(\.index), [0])
            XCTAssertEqual(manifest.totalBytes, Int64(freshBytes.count))
        } else {
            XCTAssertEqual(terminal?.state, .completed)
            XCTAssertEqual(try Data(contentsOf: chapterURL), bytes)
            let manifest = try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: manifestURL))
            XCTAssertEqual(manifest.chapters.map(\.index), [0])
            XCTAssertEqual(manifest.totalBytes, Int64(bytes.count))
        }
    }
}
#endif
