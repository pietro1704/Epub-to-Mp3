#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
#if os(iOS)
import UIKit
#endif

@testable import EpubToMp3

extension AudioPlayerPendingSeekTests {
    @MainActor
    func testFifteenThirtyAndSixtySecondSkipsCrossFileChapterBoundaries() async throws {
        try await withPlayingFixture(fileChapterDuration: 40, providesFileDurations: false, includeReadyThirdChapter: true) { player, snapshot in
            player.pause()
            for (seconds, following, forwardTime, preceding, backwardTime) in [
                (15.0, 1, 10.0, 1, 30.0),
                (30.0, 1, 25.0, 1, 15.0),
                (60.0, 2, 15.0, 0, 25.0)
            ] {
                player.play(snapshot: snapshot(true), startingAt: 0, restoreAutoplay: false)
                player.seek(to: 35)
                try await self.waitForNavigation(player)
                player.skipForward(seconds: seconds)
                try await self.waitForNavigation(player)
                XCTAssertEqual(player.currentChapterIndex, following)
                XCTAssertEqual(player.positionSeconds, forwardTime, accuracy: 0.15)
                XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, forwardTime, accuracy: 0.15)
                XCTAssertFalse(player.isPlaying)

                player.play(snapshot: snapshot(true), startingAt: 2, restoreAutoplay: false)
                player.seek(to: 5)
                try await self.waitForNavigation(player)
                player.skipBackward(seconds: seconds)
                try await self.waitForNavigation(player)
                XCTAssertEqual(player.currentChapterIndex, preceding)
                XCTAssertEqual(player.positionSeconds, backwardTime, accuracy: 0.15)
                XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, backwardTime, accuracy: 0.15)
                XCTAssertFalse(player.isPlaying)
            }

            player.play(snapshot: snapshot(true), startingAt: 0, restoreAutoplay: false)
            player.seek(to: 35)
            try await self.waitForNavigation(player)
            player.resume()
            player.skipForward(seconds: 15)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertTrue(player.isPlaying)
        }
    }

    @MainActor
    func testStreamingSkipCarriesRemainderWhenCurrentChapterFinishesLate() async throws {
        try await withPlayingFixture(streaming: true, streamSegmentCount: 1) { player, snapshot in
            player.pause()
            player.seek(to: 10)
            try await self.waitForNavigation(player)
            player.skipForward(seconds: 15)
            XCTAssertTrue(player.isSeeking)
            player.setSnapshot(snapshot(true))
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertEqual(player.positionSeconds, 10, accuracy: 0.15)
            XCTAssertFalse(player.isPlaying)
            player.skipBackward(seconds: 15)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 0)
            XCTAssertEqual(player.positionSeconds, 10, accuracy: 0.15)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 10, accuracy: 0.15)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testChapterRelativeSeekSelectsRetainedSegmentAndRestoresBaseWhilePaused() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 35)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 2)
            let item = try XCTUnwrap(player.services.queue.player?.currentItem)
            XCTAssertEqual(item.currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
            // A periodic tick must keep the chapter clock, not publish 5 s.
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)

            player.seek(to: 2)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 0)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 2, accuracy: 0.1)
            player.seek(to: 0)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.positionSeconds, 0, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testSkipBackwardCrossesSegmentsUsingChapterClockAndPreservesPause() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 35)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.durationSeconds, 180, accuracy: 0.1)
            player.skipBackward(seconds: 15)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 1)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 20, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    // SKIP-BACK-15S: a backward skip that leaves the generated audio restarts from the estimated text position
    // instead of loading forever; inside the retained audio it seeks there, and repeated taps accumulate.
    @MainActor
    func testSkipBackwardBeforeTheGeneratedOriginRestartsFromTheEstimatedTextPosition() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.setSegmentChapterEstimate(180, forChapterIndex: 0, startingRatio: 0.5)
            let origin = player.services.segments.startingPosition(for: 0)
            XCTAssertEqual(origin, 90, accuracy: 0.1)
            player.seek(to: origin + 5)
            try await self.waitForNavigation(player)
            player.skipBackward(seconds: 15)
            for _ in 0..<40 where player.pendingNavigation == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            guard case .approximateTime(let ratio)? = player.pendingNavigation?.target else {
                return XCTFail("The skip must request a restart from the estimated position, got \(String(describing: player.pendingNavigation))")
            }
            XCTAssertEqual(ratio, (origin + 5 - 15) / 180, accuracy: 0.01)
            XCTAssertTrue(player.isSeeking)
        }
    }

    @MainActor
    func testRepeatedBackwardSkipsInsideTheRetainedAudioAccumulate() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 65)
            try await self.waitForNavigation(player)
            player.skipBackward(seconds: 15)
            player.skipBackward(seconds: 15)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.2)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testBackwardSkipNearTheChapterStartLandsAtTheStartWithoutLoadingForever() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 10)
            try await self.waitForNavigation(player)
            player.skipBackward(seconds: 15)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.positionSeconds, 0, accuracy: 0.2)
        }
    }

    @MainActor
    func testSkipForwardCrossesSegmentsUsingChapterClockAndPreservesPause() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 5)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.durationSeconds, 180, accuracy: 0.1)
            player.skipForward(seconds: 30)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 2)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testSkipForwardWaitsForMissingSegmentAndPreservesPause() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     streamSegmentCount: 1) { player, snapshot in
            player.setSegmentChapterEstimate(30, forChapterIndex: 0)
            player.pause()
            player.seek(to: 5)
            try await self.waitForNavigation(player)
            player.skipForward(seconds: 30)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(player.isSeeking)
            XCTAssertEqual(player.pendingNavigation?.chapterIndex, 0)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            let data = try Data(contentsOf: url)
            player.enqueueSegment(data: data, chapterIndex: 0, segmentIndex: 1)
            player.enqueueSegment(data: data, chapterIndex: 0, segmentIndex: 2)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 2)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testSkipForwardClampsConfirmedFinalChapterInsteadOfWaitingBeyondEnd() async throws {
        try await withPlayingFixture(streaming: true) { player, snapshot in
            player.pause()
            player.nextChapter()
            try await self.waitForNavigation(player)
            player.setSnapshot(snapshot(true))
            player.seek(to: 10)
            try await self.waitForNavigation(player)
            player.skipForward(seconds: 30)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertEqual(player.positionSeconds, 15, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testPauseDuringSegmentDurationLoadingWinsOverSeekAutoplay() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.seek(to: 35)
            player.pause()
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 2)
            XCTAssertFalse(player.isPlaying)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
        }
    }

    @MainActor
    func testReplacementSeekCancelsSegmentDurationLoading() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 35)
            player.seek(to: 2)
            try await self.waitForNavigation(player)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 0)
            XCTAssertEqual(player.positionSeconds, 2, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testChapterRelativeSeekWaitsForMissingSegmentThenPreservesPause() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     streamSegmentCount: 1) { player, snapshot in
            player.setSegmentChapterEstimate(60, forChapterIndex: 0)
            player.pause()
            player.seek(to: 35)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertTrue(player.isSeeking)
            XCTAssertEqual(player.pendingNavigation?.chapterIndex, 0)
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            let data = try Data(contentsOf: url)
            player.enqueueSegment(data: data, chapterIndex: 0, segmentIndex: 1)
            player.enqueueSegment(data: data, chapterIndex: 0, segmentIndex: 2)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 2)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testChapterRelativeSeekDoesNotCollapseOutOfOrderOrdinalGap() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     streamSegmentCount: 1) { player, snapshot in
            player.setSegmentChapterEstimate(60, forChapterIndex: 0)
            player.pause()
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            let data = try Data(contentsOf: url)
            player.enqueueSegment(data: data, chapterIndex: 0, segmentIndex: 2)
            player.seek(to: 20)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertTrue(player.isSeeking, "Segment 2 must not occupy missing segment 1's timeline.")
            player.enqueueSegment(data: data, chapterIndex: 0, segmentIndex: 1)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 1)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 20, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testExactSegmentBoundaryWaitsForFollowingSegmentWithUnknownChapterEnd() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     streamSegmentCount: 1) { player, snapshot in
            player.setSegmentChapterEstimate(60, forChapterIndex: 0)
            player.pause()
            player.seek(to: 15)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertTrue(player.isSeeking, "A buffered prefix's end is not the chapter end.")
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            player.enqueueSegment(data: try Data(contentsOf: url), chapterIndex: 0, segmentIndex: 1)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.services.segments.activeIdentity?.segmentIndex, 1)
            XCTAssertEqual(try XCTUnwrap(player.services.queue.player?.currentItem).currentTime().seconds, 0, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 15, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testStopCancelsChapterRelativeDurationLoadBeforeItCanRebuildQueue() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.seek(to: 35)
            player.stop()
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertNil(player.services.queue.player?.currentItem)
            XCTAssertNil(player.pendingNavigation)
            XCTAssertFalse(player.isSeeking)
            XCTAssertFalse(player.isPlaying)
        }
    }
}
#endif
