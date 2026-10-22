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
    func testNextAndPreviousStreamedChapterUseRetainedFilesAndPreservePause() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.nextChapter()
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 0)
            XCTAssertFalse(player.isPlaying)
            player.previousChapter()
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 0)
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 0)
            XCTAssertFalse(player.isPlaying)
            XCTAssertLessThanOrEqual(player.testHook_deferredSegmentCount(), 12)
        }
    }

    @MainActor
    func testNextStreamedChapterWaitsForArrivalWithoutLosingPause() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false) { player, snapshot in
            player.nextChapter()
            XCTAssertEqual(player.pendingNavigation?.chapterIndex, 1)
            XCTAssertTrue(player.isSeeking)
            player.pause()
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.last?.downloadUrl)))
            player.enqueueSegment(data: try Data(contentsOf: url), chapterIndex: 1, segmentIndex: 0)
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 0, accuracy: 0.1)
        }
    }

    @MainActor
    func testPreviousStreamedChapterRestartsWholeChapterAfterLaterSegment() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.pause()
            player.seek(to: 35)
            try await self.waitForNavigation(player)
            player.previousChapter()
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 0)
            XCTAssertEqual(player.testHook_activeSegmentIdentity()?.segmentIndex, 0)
            XCTAssertEqual(player.positionSeconds, 0, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
        }
    }

    @MainActor
    func testNextStreamedChapterBeyondActiveQueuePreservesPlayingIntent() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
            player.nextChapter()
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertTrue(player.isPlaying)
            let initial = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertGreaterThan(player.positionSeconds, initial)
        }
    }

    @MainActor
    func testSeekToNextStreamedChapterFindsItsFirstSegmentBeyondActiveQueue() async throws {
        try await withPlayingFixture(streaming: true, streamCurrentComplete: true) { player, _ in
            XCTAssertEqual(player.currentChapterIndex, 0)
            let originalIDs = Set(try exportedJourneys().map(\.id))
            player.seek(to: player.durationSeconds)
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && player.positionSeconds > 0 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1,
                           "The target exists in the segment backlog despite not being in the active queue.")
            XCTAssertTrue(player.isPlaying)
            XCTAssertFalse(player.isLoading)
            let initialPosition = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertGreaterThan(player.positionSeconds, initialPosition)
            let seeks = try exportedJourneys().filter { !originalIDs.contains($0.id) && $0.kind == .seek }
            XCTAssertEqual(seeks.count, 1)
            let completed = try XCTUnwrap(seeks.first)
            XCTAssertEqual(completed.records.filter { $0.transition == .seekTargetReached }.count, 1)
        }
    }

    @MainActor
    func testRemoteLastStreamedChapterDoesNotWaitForPhantomChapter() async throws {
        try await withPlayingFixture(streaming: true, streamCurrentComplete: true, snapshotIndexBase: 1) { player, snapshot in
            player.seek(to: player.durationSeconds)
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && player.positionSeconds > 0 && !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1,
                           "Remote manifest chapters 1 and 2 must play as segment chapters 0 and 1.")
            XCTAssertTrue(player.isPlaying)
            XCTAssertFalse(player.isSeeking)
            player.setSnapshot(snapshot(true))
            player.seek(to: player.durationSeconds)
            for _ in 0..<100 {
                if !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertNil(player.pendingNavigation,
                         "Seeking the last remote chapter's end must not request a nonexistent third chapter.")
            XCTAssertFalse(player.isSeeking,
                           "A one-based manifest must not leave the last zero-based segment waiting forever.")
        }
    }

    @MainActor
    func testRemoteFinalChapterFilesFulfillPendingSegmentSeekWithoutReplayingFirstChapter() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     snapshotIndexBase: 1) { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            XCTAssertEqual(player.pendingNavigation?.chapterIndex, 1,
                           "Pending streamed navigation uses the zero-based segment target.")
            player.finishStreaming(snapshot: snapshot(true))
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && player.positionSeconds > 0 && !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1,
                           "Segment target 1 must resolve to manifest chapter 2, not replay manifest chapter 1.")
            let item = try XCTUnwrap(player.testHook_currentPlayerItem())
            let asset = try XCTUnwrap(item.asset as? AVURLAsset)
            let target = try XCTUnwrap(snapshot(true).chapterProgress?.first { $0.index == 2 }?.downloadUrl)
            XCTAssertEqual(asset.url, URL(string: target),
                           "The actual queued audio must be the second chapter's distinct file.")
            XCTAssertTrue(player.isPlaying)
            XCTAssertFalse(player.isSeeking)
            XCTAssertNil(player.pendingNavigation)
            let journey = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertFalse(journey.records.contains { $0.transition == .cancelled })
            XCTAssertEqual(journey.records.filter { $0.transition == .seekTargetReached }.count, 1)
        }
    }

    @MainActor
    func testArrivingMiddleChapterPreservesAlreadyQueuedSuccessor() async throws {
        try await withPlayingFixture(includeReadyThirdChapter: true) { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            XCTAssertEqual(player.currentChapterIndex, 0,
                           "A ready later chapter must not bypass the requested middle chapter.")
            player.updateSnapshot(snapshot(true))
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && player.positionSeconds > 0 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertTrue(player.isPlaying)
            let completed = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertEqual(completed.records.filter { $0.transition == .seekTargetReached }.count, 1)

            player.nextChapter()
            for _ in 0..<100 {
                if player.currentChapterIndex == 2 && player.positionSeconds > 0 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 2,
                           "Promoting the newly ready middle chapter must preserve its queued successor.")
            XCTAssertTrue(player.isPlaying)
            let position = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertGreaterThan(player.positionSeconds, position)
        }
    }

    @MainActor
    func testFinalChapterFilesFulfillTheSamePendingSegmentSeek() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false) { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            XCTAssertEqual(player.currentChapterIndex, 0)
            player.finishStreaming(snapshot: snapshot(true))
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && player.positionSeconds > 0 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1,
                           "Final chapter files must satisfy navigation waiting for a streamed target.")
            XCTAssertTrue(player.isPlaying)
            XCTAssertFalse(player.isLoading)
            let position = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertGreaterThan(player.positionSeconds, position)
            let journey = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertFalse(journey.records.contains { $0.transition == .cancelled },
                           "Segment-to-file handoff must preserve the pending journey identity.")
            XCTAssertEqual(journey.records.filter { $0.transition == .seekTargetReached }.count, 1)
        }
    }

    @MainActor
    func testPromotingStreamedChapterReleasesWaitingProducerCapacity() async throws {
        try await withPlayingFixture(streaming: true, streamSegmentCount: 60) { player, _ in
            player.pause()
            var producerStarted = false
            var capacityResult: Bool?
            let producer = Task { @MainActor in
                producerStarted = true
                capacityResult = await player.waitForSegmentCapacity()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(producerStarted)
            XCTAssertNil(capacityResult, "The full deferred queue must initially suspend the producer.")

            player.nextChapter()
            for _ in 0..<100 {
                if capacityResult != nil && player.currentChapterIndex == 1 { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertFalse(player.isPlaying, "Keep playback paused so natural draining cannot hide the missing wakeup.")
            XCTAssertEqual(capacityResult, true,
                           "Discarding the previous chapter backlog must release the waiting producer.")
            // Stop also resolves a stuck continuation on the red path, so a
            // failing assertion never leaves a producer task behind.
            player.stop()
            await producer.value
        }
    }
}
#endif
