#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
#if os(iOS)
import UIKit
#endif

@testable import EpubToMp3

extension AudioPlayerPendingSeekTests {
#if os(iOS)
    @MainActor
    func testRetiredPlayerDeinitCannotDeactivateNewPlayersAudioSession() async throws {
        var retired: AudioPlayer?
        weak var released: AudioPlayer?
        try await withPlayingFixture { player, _ in
            retired = player
            released = player
            player.stop()
        }
        XCTAssertNotNil(retired)
        // Release the old instance after the new one activated its session,
        // before its first media tick. This pins the real replacement pattern.
        try await withPlayingFixture(afterResume: { retired = nil }) { player, _ in
            XCTAssertNil(released, "The old player must actually deinitialize.")
            XCTAssertTrue(player.isPlaying)
            let position = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertGreaterThan(player.positionSeconds, position,
                                 "Retiring another player must not deactivate this instance's audio session.")
        }
    }
#endif

    @MainActor
    func testReaderPageChoiceWaitsForUnknownChapterDurationAndKeepsItsRatio() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     providesStreamEstimates: false) { player, snapshot in
            XCTAssertEqual(player.durationSeconds, 0, "A playable segment must not imply a known chapter duration.")
            player.pause()
            player.startFromReaderPage(1, sentenceOffsetRatio: 0.5)
            XCTAssertEqual(player.pendingNavigation?.chapterIndex, 1)
            let url = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.last?.downloadUrl)))
            player.enqueueSegment(data: try Data(contentsOf: url), chapterIndex: 1, segmentIndex: 0)
            player.updateSnapshot(snapshot(true))
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 7.5, accuracy: 1,
                           "The chosen page must survive duration discovery, rather than restarting at zero.")
            XCTAssertTrue(player.isPlaying)
        }
    }

    @MainActor
    func testReaderPageRatioSurvivesStreamingFinalFileHandoff() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     providesStreamEstimates: false) { player, snapshot in
            XCTAssertEqual(player.durationSeconds, 0, "The final-file journey must start without a chapter estimate.")
            player.pause()
            player.startFromReaderPage(1, sentenceOffsetRatio: 0.5)
            XCTAssertEqual(player.pendingNavigation?.chapterIndex, 1)
            player.finishStreaming(snapshot: snapshot(true))
            try await self.waitForNavigation(player)
            let targetItem = try XCTUnwrap(player.testHook_currentPlayerItem())
            // A completed seek can precede readiness of the replacement item.
            // Its clock is authoritative only after AVFoundation prepares it.
            for _ in 0..<100 {
                if targetItem.status != .unknown { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(targetItem.status, .readyToPlay)
            XCTAssertTrue(player.testHook_currentPlayerItem() === targetItem)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertEqual(targetItem.currentTime().seconds, 7.5, accuracy: 1)
            XCTAssertTrue(player.isPlaying)
            let resumedPosition = targetItem.currentTime().seconds
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertGreaterThan(targetItem.currentTime().seconds, resumedPosition)
            XCTAssertTrue(player.testHook_currentPlayerItem() === targetItem)
        }
    }

#if os(iOS)
    @MainActor
    func testPendingNavigationShowsLoadingWithoutHidingMiniPlayerTransport() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false) { player, _ in
            player.nextChapter()
            XCTAssertTrue(player.isSeeking)
            XCTAssertTrue(player.isLoading)
            let suite = "pending-mini-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let mini = MiniPlayerBarUIKitView()
            mini.configure(player: player, playbackClock: player.playbackClock,
                           library: LibraryStore(defaults: defaults), onTap: {})
            @MainActor func buttons(_ view: UIView) -> [UIButton] {
                view.subviews.flatMap { ($0 as? UIButton).map { [$0] } ?? buttons($0) }
            }
            let transport = try XCTUnwrap(buttons(mini).first {
                $0.accessibilityIdentifier == "miniPlayer.playPause"
            })
            XCTAssertFalse(transport.isHidden, "The listener must be able to change autoplay intent while waiting.")
            transport.sendActions(for: .touchUpInside)
            XCTAssertFalse(player.isPlaying)
        }
    }
#endif

    @MainActor
    func testSeekPastAvailableChapterDoesNotReportPendingChapterReached() async throws {
        try await withPlayingFixture { player, snapshot in
        let originalIDs = Set(LatencyObservationStore.shared.snapshot().map(\.id))

        player.seek(to: player.durationSeconds)
        try await Task.sleep(nanoseconds: 300_000_000)

        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self,
                                               from: LatencyObservationStore.shared.exportData())
        let seeks = exported.filter { !originalIDs.contains($0.id) && $0.kind == .seek }
        XCTAssertEqual(seeks.count, 1)
        let journey = try XCTUnwrap(seeks.first)
        XCTAssertEqual(journey.records.first?.transition, .seekRequested)
        XCTAssertFalse(journey.records.contains { $0.transition == .seekTargetReached },
                       "The unavailable next chapter cannot be reported as reached.")
        XCTAssertFalse(journey.records.contains { $0.transition == .cancelled },
                       "Waiting for conversion must retain the requested navigation.")
        XCTAssertEqual(player.currentChapterIndex, 0,
                       "An unavailable chapter must not become the active audio chapter.")
        XCTAssertTrue(player.isLoading, "The retained navigation must remain visibly pending.")

        player.updateSnapshot(snapshot(true))
        for _ in 0..<100 {
            if player.currentChapterIndex == 1 && player.positionSeconds > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(player.currentChapterIndex, 1)
        XCTAssertGreaterThan(player.positionSeconds, 0,
                             "The retained request must start playback when its target arrives.")
        XCTAssertTrue(player.isPlaying, "The retained play intent must resume the target chapter.")
        let positionAfterArrival = player.positionSeconds
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertGreaterThan(player.positionSeconds, positionAfterArrival,
                             "The target timeline must advance, not reuse the previous position.")
        let completedExport = try JSONDecoder().decode([LatencyObservation.Journey].self,
                                                      from: LatencyObservationStore.shared.exportData())
        let completed = try XCTUnwrap(completedExport.first { $0.id == journey.id })
        XCTAssertEqual(completed.records.filter { $0.transition == .seekTargetReached }.count, 1,
                       "Complete the same pending journey once its target is available.")
        }
    }

    @MainActor
    func testStopCancelsPendingSeekBeforeTargetArrives() async throws {
        try await withPlayingFixture { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            player.stop()
            player.updateSnapshot(snapshot(true))
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.isLoading)
            let journey = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertTrue(journey.records.contains { $0.transition == .cancelled })
            XCTAssertFalse(journey.records.contains { $0.transition == .seekTargetReached },
                           "A stopped request must not finish when a later snapshot arrives.")
        }
    }

    @MainActor
    func testPauseWhileWaitingDoesNotAutoplayArrivingChapter() async throws {
        try await withPlayingFixture { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            player.pause()
            player.updateSnapshot(snapshot(true))
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && !player.isLoading { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1,
                           "Pause preserves the navigation while withdrawing autoplay intent.")
            XCTAssertFalse(player.isPlaying)
            let pausedPosition = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.positionSeconds, pausedPosition, accuracy: 0.05)
            let journey = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertFalse(journey.records.contains { $0.transition == .cancelled })
            XCTAssertEqual(journey.records.filter { $0.transition == .seekTargetReached }.count, 1)
        }
    }

    @MainActor
    func testNewSeekWithinChapterSupersedesPendingChapterNavigation() async throws {
        try await withPlayingFixture { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            let beforeReplacement = Set(try exportedJourneys().map(\.id))
            player.seek(to: 2)
            for _ in 0..<100 {
                let completed = try exportedJourneys().contains { journey in
                    !beforeReplacement.contains(journey.id) && journey.kind == .seek &&
                        journey.records.contains { $0.transition == .seekTargetReached }
                }
                if completed { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            player.updateSnapshot(snapshot(true))
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.currentChapterIndex, 0,
                           "The old boundary request must not override the newer seek.")
            XCTAssertFalse(player.isLoading)
            XCTAssertGreaterThanOrEqual(player.positionSeconds, 1.9)
            XCTAssertTrue(player.isPlaying,
                          "Replacing a waiting seek must preserve the original playback intent.")
            let replacementPosition = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertGreaterThan(player.positionSeconds, replacementPosition,
                                 "The replacement seek must resume the real media timeline.")
            let journeys = try exportedJourneys()
            let old = try XCTUnwrap(journeys.first { $0.id == pendingID })
            XCTAssertTrue(old.records.contains { $0.transition == .cancelled })
            XCTAssertFalse(old.records.contains { $0.transition == .seekTargetReached })
            let replacement = journeys.filter { !beforeReplacement.contains($0.id) && $0.kind == .seek }
            XCTAssertEqual(replacement.count, 1)
            XCTAssertTrue(try XCTUnwrap(replacement.first).records.contains { $0.transition == .seekTargetReached })
        }
    }

    @MainActor
    func testSkipBackSupersedesPendingChapterNavigation() async throws {
        try await withPlayingFixture { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            player.skip(by: -15)
            player.updateSnapshot(snapshot(true))
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.currentChapterIndex, 0,
                           "New backward intent must supersede a pending forward navigation.")
            XCTAssertFalse(player.isLoading)
            let previous = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertTrue(previous.records.contains { $0.transition == .cancelled })
            XCTAssertFalse(previous.records.contains { $0.transition == .seekTargetReached })
        }
    }

    @MainActor
    func testRepeatedBoundarySeekPreservesAutoplayIntent() async throws {
        try await verifyRepeatedBoundarySeek(pausingBetweenRequests: false)
    }

    @MainActor
    func testPauseDuringReplacementSeekPreventsCallbackFromRestoringAutoplay() async throws {
        try await withPlayingFixture { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            let originalIDs = Set(try exportedJourneys().map(\.id))
            // Do not suspend between these actions: pause must precede the
            // asynchronous seek-completion callback on the main actor.
            player.seek(to: 2)
            player.pause()
            for _ in 0..<100 {
                let reached = try exportedJourneys().contains { journey in
                    !originalIDs.contains(journey.id) && journey.kind == .seek &&
                        journey.records.contains { $0.transition == .seekTargetReached }
                }
                if reached { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            player.updateSnapshot(snapshot(true))
            XCTAssertEqual(player.currentChapterIndex, 0)
            XCTAssertFalse(player.isPlaying)
            XCTAssertFalse(player.isLoading)
            XCTAssertEqual(player.positionSeconds, 2, accuracy: 0.1)
            let pausedPosition = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertFalse(player.isPlaying,
                           "An asynchronous seek callback must respect a subsequent explicit pause.")
            XCTAssertEqual(player.positionSeconds, pausedPosition, accuracy: 0.05)
            let journeys = try exportedJourneys()
            let superseded = try XCTUnwrap(journeys.first { $0.id == pendingID })
            XCTAssertTrue(superseded.records.contains { $0.transition == .cancelled })
            XCTAssertFalse(superseded.records.contains { $0.transition == .seekTargetReached })
            let replacement = journeys.filter { !originalIDs.contains($0.id) && $0.kind == .seek }
            XCTAssertEqual(replacement.count, 1)
            let completed = try XCTUnwrap(replacement.first)
            XCTAssertEqual(completed.records.filter { $0.transition == .seekTargetReached }.count, 1)
        }
    }

    @MainActor
    func testPauseBetweenRepeatedBoundarySeeksRemainsPausedOnArrival() async throws {
        try await verifyRepeatedBoundarySeek(pausingBetweenRequests: true)
    }
}
#endif
