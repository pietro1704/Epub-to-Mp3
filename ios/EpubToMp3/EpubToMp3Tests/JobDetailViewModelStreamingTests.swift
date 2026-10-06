import MediaPlayer
import XCTest
@testable import EpubToMp3

#if os(iOS)
private final class InMemoryJobStreamingClient: JobStreamingClient, @unchecked Sendable {
    private let snapshot: JobSnapshot
    private let manifest: APIClient.ChapterStreamManifest
    private let chunk: Data
    private let onDownload: (@Sendable (StreamingDiagnosticsSession.Authorization?) async -> APIClient.StreamChunkDownload)?
    private let manifests: [Int: APIClient.ChapterStreamManifest]
    private let requestLock = NSLock()
    private var downloadedChapters: [Int] = []
    var downloadedChapterIndices: [Int] {
        requestLock.lock(); defer { requestLock.unlock() }; return downloadedChapters
    }
    private func recordDownload(chapter: Int) {
        requestLock.lock(); downloadedChapters.append(chapter); requestLock.unlock()
    }

    init(
        snapshot: JobSnapshot,
        manifest: APIClient.ChapterStreamManifest,
        chunk: Data,
        onDownload: (@Sendable (StreamingDiagnosticsSession.Authorization?) async -> APIClient.StreamChunkDownload)? = nil,
        manifests: [Int: APIClient.ChapterStreamManifest] = [:]
    ) {
        self.snapshot = snapshot
        self.manifest = manifest
        self.chunk = chunk
        self.onDownload = onDownload
        self.manifests = manifests
    }

    func fetchJob(id: String) async throws -> JobSnapshot {
        return snapshot
    }

    func fetchChapterStream(
        jobId: String,
        chapterIndex: Int
    ) async throws -> APIClient.ChapterStreamManifest {
        return manifests[chapterIndex] ?? manifest
    }

    func fetchChapterStreamChunk(
        jobId: String,
        chapterIndex: Int,
        chunkId: String
    ) async throws -> Data {
        recordDownload(chapter: chapterIndex)
        return chunk
    }

    func eventStream(jobId: String) -> AsyncThrowingStream<JobEvent, Error> {
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func fetchChapterStreamChunk(
        jobId: String, chapterIndex: Int, chunkId: String,
        authorization: StreamingDiagnosticsSession.Authorization?
    ) async throws -> APIClient.StreamChunkDownload {
        recordDownload(chapter: chapterIndex)
        if let onDownload { return await onDownload(authorization) }
        return .init(data: chunk, receipt: nil)
    }
}

@MainActor
private final class StreamingTestState {
    var viewModel: JobDetailViewModel?
    var authorization: StreamingDiagnosticsSession.Authorization?
}

final class JobDetailViewModelStreamingTests: XCTestCase {
    @MainActor
    func testEmptyEarlierManifestSelectsLateChapterBeforeAuthorizedDownload() async throws {
        let identifier = "SparseOwner-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let previousWidgetBook = widget?.object(forKey: "currentlyPlayingBookId")
        widget?.set("", forKey: "currentlyPlayingBookId")
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(identifier, forKey: AudioPlayer.currentBookIDDefaultsKey)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let viewModel = JobDetailViewModel()
        defer {
            viewModel.stop()
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widget?.set(previousWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
        }
        let snapshot = JobSnapshot(jobId: identifier, state: "running", bookTitle: nil, bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
            progressPercent: 0, chaptersTotal: 2, chaptersCompleted: 0,
            chapterProgress: [1, 14].map { index in
                .init(index: index, name: "Chapter", status: "processing", downloadUrl: nil,
                    chars: 10, charsProcessed: 0, progressRatio: 0, durationSeconds: nil, startedAt: nil, completedAt: nil)
            }, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        XCTAssertTrue(player.beginRemoteStreaming(snapshot: snapshot, backendBaseURL: URL(string: "https://sparse.invalid")!))
        player.resume()
        let generation = try XCTUnwrap(player.remoteSegmentGeneration)
        let state = StreamingTestState()
        let publicationID = UUID().uuidString
        let requestID = UUID()
        let bytes = Data([0x49, 0x44, 0x33, 0x04])
        let late = APIClient.ChapterStreamManifest(chapterIndex: 14,
            chunks: [.init(id: publicationID, index: 7, url: "/unused", text: nil)])
        let client = InMemoryJobStreamingClient(snapshot: snapshot, manifest: late, chunk: bytes,
            onDownload: { authorization in
                let selected = await MainActor.run { state.authorization?.journeyID }
                XCTAssertNotNil(selected, "The player must authorize the selected chapter before its GET")
                XCTAssertEqual(authorization?.journeyID, selected)
                let receipt = authorization.flatMap {
                    LatencyObservation.StreamRequestReceipt(journeyID: $0.journeyID,
                        requestID: requestID, publicationID: publicationID)
                }
                return .init(data: bytes, receipt: receipt)
            }, manifests: [1: .init(chapterIndex: 1, chunks: []), 14: late])
        let received = expectation(description: "First available late chapter reaches delivery")
        viewModel.onStreamRequestAuthorization = { job, chapter, segment in
            XCTAssertEqual(job, identifier)
            XCTAssertEqual(chapter, 14, "An empty manifest must not authorize any GET")
            XCTAssertEqual(segment, 7)
            let authorization = player.streamRequestAuthorization(jobID: job, generation: generation,
                chapterIndex: chapter, segmentIndex: segment, session: diagnostics)
            state.authorization = authorization
            return authorization
        }
        viewModel.onStreamChunk = { [weak viewModel] data, chapter, segment, _, receipt in
            XCTAssertEqual(data, bytes)
            XCTAssertEqual(chapter, 13)
            XCTAssertEqual(segment, 7)
            XCTAssertNotNil(receipt)
            XCTAssertEqual(receipt?.journeyID, state.authorization?.journeyID)
            XCTAssertEqual(receipt?.requestID, requestID)
            XCTAssertEqual(client.downloadedChapterIndices, [14])
            viewModel?.stop()
            received.fulfill()
        }
        viewModel.start(client: client, jobId: identifier)
        await fulfillment(of: [received], timeout: 3)
    }

    @MainActor
    func testAuthorizationIsCapturedBeforeDownloadAndReceiptIsForwardedWithoutRetagging() async throws {
        let diagnostics = StreamingDiagnosticsSession()
        diagnostics.activate()
        let original = try XCTUnwrap(diagnostics.authorization(for: UUID()))
        let replacement = try XCTUnwrap(diagnostics.authorization(for: UUID()))
        let state = StreamingTestState()
        state.authorization = original
        let publicationID = UUID().uuidString
        let receipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
            journeyID: original.journeyID, requestID: UUID(), publicationID: publicationID))
        let bytes = Data([0x49, 0x44, 0x33, 0x04])
        let snapshot = JobSnapshot(jobId: "captured", state: "running", bookTitle: nil, bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
            progressPercent: 0, chaptersTotal: 1, chaptersCompleted: 0,
            chapterProgress: [.init(index: 3, name: "Target", status: "processing", downloadUrl: nil,
                chars: 10, charsProcessed: 0, progressRatio: 0, durationSeconds: nil, startedAt: nil, completedAt: nil)],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        let client = InMemoryJobStreamingClient(snapshot: snapshot,
            manifest: .init(chapterIndex: 3, chunks: [.init(id: publicationID, index: 7, url: "/unused", text: nil)]),
            chunk: bytes, onDownload: { authorization in
                XCTAssertEqual(authorization?.journeyID, original.journeyID)
                await Task.yield()
                await MainActor.run { state.authorization = replacement }
                return .init(data: bytes, receipt: receipt)
            })
        let received = expectation(description: "Captured request reaches stream delivery")
        let viewModel = JobDetailViewModel()
        defer { viewModel.stop() }
        viewModel.onStreamRequestAuthorization = { job, chapter, segment in
            XCTAssertEqual(job, "captured")
            XCTAssertEqual(chapter, 3, "Authorization uses canonical backend chapter identity")
            XCTAssertEqual(segment, 7)
            return state.authorization
        }
        viewModel.onStreamChunk = { [weak viewModel] data, chapter, segment, _, deliveredReceipt in
            XCTAssertEqual(data, bytes)
            XCTAssertEqual(chapter, 2)
            XCTAssertEqual(segment, 7)
            XCTAssertEqual(state.authorization?.journeyID, replacement.journeyID)
            XCTAssertEqual(deliveredReceipt, receipt)
            viewModel?.stop()
            received.fulfill()
        }
        viewModel.start(client: client, jobId: snapshot.jobId)
        await fulfillment(of: [received], timeout: 3)
    }

    func testRemoteChunkFlowsFromManifestWithCanonicalMetadata() throws {
        let producer = try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
            #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":40,"artifactPublishedElapsedNanoseconds":55}"#.utf8))
        let publicationID = UUID().uuidString
        let snapshot = JobSnapshot(
            jobId: "remote-stream",
            state: "running",
            bookTitle: "Remote Book",
            bookAuthor: "Remote Author",
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: 20,
            chaptersTotal: 1,
            chaptersCompleted: 0,
            chapterProgress: [
                .init(
                    index: 1,
                    name: "The Real Chapter",
                    status: "processing",
                    downloadUrl: nil,
                    chars: 64,
                    charsProcessed: 12,
                    progressRatio: 0.2,
                    durationSeconds: nil,
                    startedAt: nil,
                    completedAt: nil
                )
            ],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
        let manifest = APIClient.ChapterStreamManifest(
            chapterIndex: 1,
            chunks: [
                .init(
                    id: publicationID,
                    index: 0,
                    url: "/api/streams/remote-stream/chapters/1/chunks/chunk-0",
                    text: "First sentence",
                    observation: producer
                )
            ]
        )
        let client = InMemoryJobStreamingClient(
            snapshot: snapshot,
            manifest: manifest,
            chunk: Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00])
        )
        let chunkReceived = expectation(description: "Remote stream chunk reaches the player bridge")

        Task { @MainActor in
            let state = StreamingTestState()
            let player = AudioPlayer()
            let viewModel = JobDetailViewModel()
            state.viewModel = viewModel
            viewModel.onSnapshot = { incomingSnapshot in
                XCTAssertTrue(player.beginRemoteStreaming(
                    snapshot: incomingSnapshot,
                    backendBaseURL: URL(string: "https://streaming.test")!
                ))
            }
            viewModel.onStreamChunk = { data, chapterIndex, segmentIndex, publication, receipt in
                XCTAssertNil(receipt)
                XCTAssertEqual(publication?.publicationID, publicationID)
                XCTAssertEqual(publication?.producer, producer)
                XCTAssertEqual(data.count, 7)
                XCTAssertEqual(chapterIndex, 0, "Backend index 1 must become player index 0")
                XCTAssertEqual(segmentIndex, 0)
                XCTAssertEqual(player.effectiveChapterTitle, "The Real Chapter")
                let nowPlaying = player.makeNowPlayingInfo()
                XCTAssertEqual(nowPlaying[MPMediaItemPropertyTitle] as? String, "The Real Chapter")
                XCTAssertEqual(nowPlaying[MPMediaItemPropertyAlbumTitle] as? String, "Remote Book")
                state.viewModel?.stop()
                state.viewModel = nil
                chunkReceived.fulfill()
            }
            viewModel.start(client: client, jobId: snapshot.jobId)
        }
        wait(for: [chunkReceived], timeout: 3)
    }
}
#endif
