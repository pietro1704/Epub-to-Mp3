#if canImport(AVFoundation) && canImport(MediaPlayer)
import Combine
import Foundation
import XCTest
@testable import EpubToMp3

final class PlaybackReadinessPublicationTests: XCTestCase {
    @MainActor
    func testCoordinatorForwardsExactlyOneSynchronousWillChangePerAssignment() {
        let player = AudioPlayer()
        var previous: [(Bool, Double?)] = []
        let observation = player.objectWillChange.sink {
            previous.append((player.isConverting, player.conversionProgress))
        }
        defer { observation.cancel() }
        player.isConverting = true
        XCTAssertEqual(previous.count, 1)
        XCTAssertFalse(previous[0].0, "Forwarding must retain @Published will-set ordering")
        XCTAssertNil(previous[0].1)
        XCTAssertTrue(player.isConverting)
        player.conversionProgress = 0.5
        XCTAssertEqual(previous.count, 2, "A composed owner must not double-publish through the coordinator")
        XCTAssertTrue(previous[1].0)
        XCTAssertNil(previous[1].1)
        XCTAssertEqual(player.conversionProgress, 0.5)
        player.conversionProgress = 0.5
        XCTAssertEqual(previous.count, 3, "Published assignments must not gain implicit deduplication")
        XCTAssertEqual(previous[2].1, 0.5)
    }

    @MainActor
    func testConversionCancellationKeepsAudibleReadinessUntilTransportIsReleased() {
        let player = AudioPlayer()
        player.markFirstChapterReady()
        player.testHook_setIsPlaying(true)
        player.isConverting = true
        player.conversionProgress = 0.5
        player.clearConversionState()
        XCTAssertFalse(player.isConverting)
        XCTAssertNil(player.conversionProgress)
        XCTAssertTrue(player.firstChapterReady, "Cancellation cannot hide an existing transport")
        player.testHook_setIsPlaying(false)
        player.clearConversionState()
        XCTAssertFalse(player.firstChapterReady)
        XCTAssertFalse(player.firstSegmentReady)
    }

    @MainActor
    func testNewBookIdentityClearsPreviousReadinessWithoutGrantingAutoplay() throws {
        let fixture = try PlaybackPublicationFixture()
        let player = AudioPlayer(resumeStore: fixture.resumeStore)
        defer { fixture.restore(afterStopping: player) }
        let first = try JSONDecoder().decode(JobSnapshot.self, from: Data(#"{"jobId":"first-book","state":"running","chaptersTotal":1,"chaptersCompleted":0}"#.utf8))
        let second = try JSONDecoder().decode(JobSnapshot.self, from: Data(#"{"jobId":"second-book","state":"running","chaptersTotal":1,"chaptersCompleted":0}"#.utf8))
        let base = try XCTUnwrap(URL(string: "https://example.invalid"))
        XCTAssertTrue(player.beginRemoteStreaming(snapshot: first, backendBaseURL: base))
        player.markFirstChapterReady()
        let generation = player.remotePlaybackGeneration
        XCTAssertTrue(player.beginRemoteStreaming(snapshot: second, backendBaseURL: base))
        XCTAssertNotEqual(player.remotePlaybackGeneration, generation)
        XCTAssertEqual(player.snapshot?.jobId, "second-book")
        XCTAssertFalse(player.firstChapterReady)
        XCTAssertFalse(player.firstSegmentReady)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasLoadedAudioQueue)
        XCTAssertTrue(player.isConverting)
    }
}
#endif
