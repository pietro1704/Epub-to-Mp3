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
    func testChapterRelativeSeekSelectsRetainedSegmentAndRestoresBaseWhilePaused() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 35)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 2)
            let item = try XCTUnwrap(player.testHook_currentPlayerItem())
            XCTAssertEqual(item.currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
            // A periodic tick must keep the chapter clock, not publish 5 s.
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)

            player.seek(to: 2)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 0)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 2, accuracy: 0.1)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 1)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 5, accuracy: 0.1)
            XCTAssertEqual(player.positionSeconds, 20, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 2)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 5, accuracy: 0.1)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 2)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 5, accuracy: 0.1)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 2)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 0)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 2)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 5, accuracy: 0.1)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 1)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 5, accuracy: 0.1)
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
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 1)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 0, accuracy: 0.1)
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
            XCTAssertNil(player.testHook_currentPlayerItem())
            XCTAssertNil(player.pendingNavigation)
            XCTAssertFalse(player.isSeeking)
            XCTAssertFalse(player.isPlaying)
        }
    }
}
#endif
