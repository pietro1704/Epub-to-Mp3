#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import XCTest
@testable import EpubToMp3

extension AudioPlayerPendingSeekTests {
    @MainActor
    func testDistantPausedSeekLetsBoundedProducerReachContainingChunk() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     streamSegmentCount: 1) { player, snapshot in
            player.pause()
            player.setSegmentChapterEstimate(300, forChapterIndex: 0)
            player.seek(to: 155)
            let requested = try XCTUnwrap(player.pendingNavigation)
            XCTAssertEqual(requested.target, .chapterTime(155))
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            let bytes = try Data(contentsOf: url)
            let finished = self.expectation(description: "The bounded producer reaches segment ten while paused")
            var accepted: [Bool] = []
            let producer = Task { @MainActor in
                for index in 1...10 {
                    accepted.append(await player.enqueueSegmentAsync(data: bytes, chapterIndex: 0,
                        segmentIndex: index, maximumDeferredSegments: 2))
                }
                finished.fulfill()
            }
            await self.fulfillment(of: [finished], timeout: 10)
            // Teardown must unblock the producer even when the regression fails.
            if accepted.count != 10 { player.stop() }
            await producer.value
            XCTAssertEqual(accepted, Array(repeating: true, count: 10))
            guard player.snapshot != nil else { return }
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 10)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 155, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
            player.seek(to: 2)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 0,
                "Releasing live queue capacity must preserve the earlier segment file.")
            XCTAssertEqual(player.positionSeconds, 2, accuracy: 0.1)
        }
    }

    @MainActor
    func testReplacingDistantSeekKeepsLatestRequestAndStopRejectsLateAudio() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     streamSegmentCount: 1) { player, snapshot in
            player.pause()
            player.seek(to: 155)
            let retired = try XCTUnwrap(player.pendingNavigation)
            player.seek(to: 35)
            let current = try XCTUnwrap(player.pendingNavigation)
            XCTAssertNotEqual(current.requestID, retired.requestID)
            XCTAssertNil(player.pendingListeningSeek(for: retired))
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            let bytes = try Data(contentsOf: url)
            for index in 1...2 { player.enqueueSegment(data: bytes, chapterIndex: 0, segmentIndex: index) }
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
            let generation = try XCTUnwrap(player.remoteSegmentGeneration)
            let jobID = try XCTUnwrap(player.snapshot?.jobId)
            player.stop()
            let accepted = await player.enqueueRemoteSegmentAsync(data: bytes, jobID: jobID,
                generation: generation, chapterIndex: 0, segmentIndex: 11, publication: nil)
            XCTAssertFalse(accepted)
            XCTAssertNil(player.pendingNavigation)
            XCTAssertNil(player.testHook_currentPlayerItem())
        }
    }
}
#endif
