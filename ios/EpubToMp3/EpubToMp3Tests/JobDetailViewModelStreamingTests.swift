import MediaPlayer
import XCTest
@testable import EpubToMp3

#if os(iOS)
private final class InMemoryJobStreamingClient: JobStreamingClient, @unchecked Sendable {
    private let snapshot: JobSnapshot
    private let manifest: APIClient.ChapterStreamManifest
    private let chunk: Data

    init(
        snapshot: JobSnapshot,
        manifest: APIClient.ChapterStreamManifest,
        chunk: Data
    ) {
        self.snapshot = snapshot
        self.manifest = manifest
        self.chunk = chunk
    }

    func fetchJob(id: String) async throws -> JobSnapshot {
        return snapshot
    }

    func fetchChapterStream(
        jobId: String,
        chapterIndex: Int
    ) async throws -> APIClient.ChapterStreamManifest {
        return manifest
    }

    func fetchChapterStreamChunk(
        jobId: String,
        chapterIndex: Int,
        chunkId: String
    ) async throws -> Data {
        return chunk
    }

    func eventStream(jobId: String) -> AsyncThrowingStream<JobEvent, Error> {
        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

@MainActor
private final class StreamingTestState {
    var viewModel: JobDetailViewModel?
}

final class JobDetailViewModelStreamingTests: XCTestCase {
    func testRemoteChunkFlowsFromManifestWithCanonicalMetadata() {
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
                    id: "chunk-0",
                    index: 0,
                    url: "/api/streams/remote-stream/chapters/1/chunks/chunk-0",
                    text: "First sentence"
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
            viewModel.onStreamChunk = { data, chapterIndex, segmentIndex in
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
