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
    func testRequestAuthorizationRequiresOptInAndMissingRequestedPlaybackSegment() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false, snapshotIndexBase: 1) { player, snapshot in
            player.stop()
            let initial = snapshot(false)
            XCTAssertTrue(player.beginRemoteStreaming(snapshot: initial, backendBaseURL: URL(string: "https://audio.invalid")!))
            let generation = try XCTUnwrap(player.remoteSegmentGeneration)
            let diagnostics = StreamingDiagnosticsSession()
            @MainActor func authorize(_ chapter: Int = 1, _ segment: Int = 0, job: String? = nil, token: UUID? = nil)
                -> StreamingDiagnosticsSession.Authorization? {
                player.streamRequestAuthorization(jobID: job ?? initial.jobId, generation: token ?? generation,
                    chapterIndex: chapter, segmentIndex: segment, session: diagnostics)
            }
            XCTAssertNil(authorize())
            player.resume()
            XCTAssertNil(authorize(), "Playback alone must not enable diagnostics")
            diagnostics.activate()
            let authorization = try XCTUnwrap(authorize())
            XCTAssertNil(authorize(2))
            XCTAssertNotNil(authorize(1, 7), "A sparse manifest's first available segment is still requested audio")
            XCTAssertNil(authorize(job: "another-job"))
            XCTAssertNil(authorize(token: UUID()))
            let publication = try self.publication()
            let receipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
                journeyID: authorization.journeyID, requestID: UUID(), publicationID: publication.publicationID))
            let source = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            let bytes = try Data(contentsOf: source)
            player.enqueueRemoteSegment(data: bytes, jobID: initial.jobId, generation: generation,
                chapterIndex: 0, segmentIndex: 7, publication: publication, receipt: receipt)
            let duplicateReceipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
                journeyID: authorization.journeyID, requestID: UUID(), publicationID: publication.publicationID))
            player.enqueueRemoteSegment(data: bytes, jobID: initial.jobId, generation: generation,
                chapterIndex: 0, segmentIndex: 7, publication: publication, receipt: duplicateReceipt)
            XCTAssertNil(authorize(), "Retained audio must not be downloaded for correlation")
            for _ in 0..<100 {
                if try self.exportedJourneys().first(where: { $0.id == authorization.journeyID })?.streamRequest != nil { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let journey = try XCTUnwrap(self.exportedJourneys().first { $0.id == authorization.journeyID })
            XCTAssertEqual(journey.streamRequest, receipt)
            XCTAssertEqual(journey.streamPublication, publication)
            player.finishStreaming(snapshot: snapshot(true))
            XCTAssertNil(player.remoteSegmentGeneration)
            XCTAssertNil(authorize())
        }
    }

    @MainActor
    func testPendingSeekAuthorizationDoesNotTransferReceiptToReplacementJourney() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false) { player, snapshot in
            let diagnostics = StreamingDiagnosticsSession()
            diagnostics.activate()
            let generation = try XCTUnwrap(player.remoteSegmentGeneration)
            let initial = snapshot(false)
            @MainActor func authorize(_ chapter: Int = 1) -> StreamingDiagnosticsSession.Authorization? {
                player.streamRequestAuthorization(jobID: initial.jobId, generation: generation,
                    chapterIndex: chapter, segmentIndex: 0, session: diagnostics)
            }
            XCTAssertNil(authorize(), "Background prefetch is not an active journey")
            player.nextChapter()
            let old = try XCTUnwrap(authorize())
            XCTAssertNil(authorize(0))
            player.nextChapter()
            let replacement = try XCTUnwrap(authorize())
            XCTAssertNotEqual(old.journeyID, replacement.journeyID)
            let publication = try self.publication()
            let receipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
                journeyID: old.journeyID, requestID: UUID(), publicationID: publication.publicationID))
            let source = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.last?.downloadUrl)))
            player.enqueueRemoteSegment(data: try Data(contentsOf: source), jobID: initial.jobId,
                generation: generation, chapterIndex: 1, segmentIndex: 0, publication: publication, receipt: receipt)
            for _ in 0..<100 {
                if !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            let journeys = try self.exportedJourneys()
            XCTAssertNil(journeys.first { $0.id == old.journeyID }?.streamRequest)
            XCTAssertNil(journeys.first { $0.id == replacement.journeyID }?.streamRequest)
            XCTAssertEqual(journeys.first { $0.id == replacement.journeyID }?.streamPublication, publication)
            player.stop()
            XCTAssertNil(authorize())
            XCTAssertTrue(player.beginRemoteStreaming(snapshot: initial, backendBaseURL: URL(string: "https://audio.invalid")!))
            player.resume()
            XCTAssertNil(authorize(0), "Reopening the same job must not revive the old delivery generation")
        }
    }

    @MainActor
    func testLateStartingChapterPlaybackCorrelatesItsActualFirstAvailableSegment() async throws {
        try await withPlayingFixture(streaming: true, streamTargetReady: false, snapshotIndexBase: 14) { player, snapshot in
            player.stop()
            let initial = snapshot(false)
            XCTAssertTrue(player.beginRemoteStreaming(snapshot: initial,
                backendBaseURL: URL(string: "https://late-start.invalid")!))
            let generation = try XCTUnwrap(player.remoteSegmentGeneration)
            let existingIDs = Set(try self.exportedJourneys().map(\.id))
            let diagnostics = StreamingDiagnosticsSession()
            diagnostics.activate()
            player.resume()
            let authorization = player.streamRequestAuthorization(
                jobID: initial.jobId, generation: generation,
                chapterIndex: 14, segmentIndex: 7, session: diagnostics)
            let publication = try self.publication()
            let receipt = authorization.flatMap {
                LatencyObservation.StreamRequestReceipt(journeyID: $0.journeyID,
                    requestID: UUID(), publicationID: publication.publicationID)
            }
            let source = try XCTUnwrap(URL(string: try XCTUnwrap(snapshot(true).playableChapters.first?.downloadUrl)))
            // A missing diagnostic authorization must not prevent the fixture
            // from proving which downloaded bytes the real player accepts.
            player.enqueueRemoteSegment(data: try Data(contentsOf: source), jobID: initial.jobId,
                generation: generation, chapterIndex: 13, segmentIndex: 7,
                publication: publication, receipt: receipt)
            for _ in 0..<120 {
                let audible = try self.exportedJourneys().contains {
                    !existingIDs.contains($0.id) && $0.kind == .progressivePlayback
                        && $0.records.contains { $0.transition == .audioAudible }
                }
                if player.positionSeconds > 0 && audible { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertTrue(player.isPlaying)
            XCTAssertGreaterThan(player.positionSeconds, 0, "The late-starting chapter must actually advance")
            XCTAssertEqual(player.currentChapterIndex, 13)
            let journey = try XCTUnwrap(self.exportedJourneys().first {
                !existingIDs.contains($0.id) && $0.kind == .progressivePlayback
                    && $0.records.contains { $0.transition == .audioAudible }
            })
            XCTAssertEqual(journey.streamPublication, publication)
            XCTAssertNotNil(authorization, "The actual first requested chapter is 14, not queue offset zero")
            XCTAssertEqual(authorization?.journeyID, journey.id)
            XCTAssertNotNil(journey.streamRequest, "Audible output must retain its authorized HTTP request receipt")
            XCTAssertEqual(journey.streamRequest, receipt)
        }
    }

    @MainActor
    func testAudibleJourneyUsesAcceptedPublicationDespiteRetriedSegmentMetadata() async throws {
        let accepted = try publication()
        let retry = try publication()
        try await withPlayingFixture(streaming: true, streamPublications: [0: accepted]) { player, snapshot in
            let original = try XCTUnwrap(exportedJourneys().first { $0.streamPublication == accepted })
            XCTAssertEqual(original.kind, .progressivePlayback)
            XCTAssertTrue(original.records.contains { $0.transition == .audioAudible })
            let url = try XCTUnwrap(player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0))
            let retainedBytes = try Data(contentsOf: url)
            player.enqueueRemoteSegment(data: retainedBytes, jobID: snapshot(false).jobId,
                generation: player.remotePlaybackGeneration, chapterIndex: 0, segmentIndex: 0, publication: retry)
            XCTAssertEqual(try Data(contentsOf: url), retainedBytes)
            player.pause()
            let existing = Set(try exportedJourneys().map(\.id))
            player.resume()
            for _ in 0..<100 {
                if try exportedJourneys().contains(where: { !existing.contains($0.id) && $0.streamPublication == accepted }) { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let replay = try XCTUnwrap(exportedJourneys().first { !existing.contains($0.id) && $0.kind == .progressivePlayback })
            XCTAssertEqual(replay.streamPublication, accepted,
                           "Rejected retry bytes must not replace the retained audio's producer identity.")
            XCTAssertFalse(try exportedJourneys().contains { $0.streamPublication == retry })
        }
    }

    @MainActor
    func testPendingSeekCorrelatesSelectedBacklogPublicationNotAudiblePredecessor() async throws {
        let predecessor = try publication()
        let target = try publication()
        let retry = try publication()
        try await withPlayingFixture(streaming: true, streamPublications: [0: predecessor, 1: target]) { player, snapshot in
            let targetURL = try XCTUnwrap(player.testHook_segmentURL(chapterIndex: 1, segmentIndex: 0))
            player.enqueueRemoteSegment(data: try Data(contentsOf: targetURL), jobID: snapshot(false).jobId,
                generation: player.remotePlaybackGeneration, chapterIndex: 1, segmentIndex: 0, publication: retry)
            let existing = Set(try exportedJourneys().map(\.id))
            player.nextChapter()
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let journey = try XCTUnwrap(exportedJourneys().first { !existing.contains($0.id) && $0.kind == .seek })
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertTrue(journey.records.contains { $0.transition == .seekTargetReached })
            XCTAssertEqual(journey.streamPublication, target)
        }
    }

    @MainActor
    func testStoppedRemoteGenerationCannotAttachAudioToReopenedSameJob() async throws {
        let stalePublication = try publication()
        try await withPlayingFixture(streaming: true, streamTargetReady: false) { player, snapshot in
            let oldGeneration = player.remotePlaybackGeneration
            let oldURL = try XCTUnwrap(player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0))
            let bytes = try Data(contentsOf: oldURL)
            let pendingID = try await beginPendingSeek(player)
            player.stop()
            XCTAssertTrue(player.beginRemoteStreaming(snapshot: snapshot(false),
                backendBaseURL: try XCTUnwrap(URL(string: "https://stream-generation.invalid"))))
            XCTAssertNotEqual(player.remotePlaybackGeneration, oldGeneration)
            player.enqueueRemoteSegment(data: bytes, jobID: snapshot(false).jobId, generation: oldGeneration,
                chapterIndex: 1, segmentIndex: 0, publication: stalePublication)
            XCTAssertEqual(player.testHook_retainedSegmentCount(), 0)
            XCTAssertNil(player.testHook_currentPlayerItem())
            let cancelled = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertNil(cancelled.streamPublication)
            XCTAssertTrue(cancelled.records.contains { $0.transition == .cancelled })
            let currentGeneration = player.remotePlaybackGeneration
            player.enqueueRemoteSegment(data: bytes, jobID: snapshot(false).jobId, generation: currentGeneration,
                chapterIndex: 0, segmentIndex: 0, publication: nil)
            XCTAssertEqual(player.testHook_retainedSegmentCount(), 1,
                           "A fresh binding must still accept audio without optional diagnostics.")
            player.updateSnapshot(snapshot(false))
            XCTAssertEqual(player.remotePlaybackGeneration, currentGeneration,
                           "Routine snapshots must not invalidate the active producer binding.")
        }
    }

    @MainActor
    func testSupersededSeekDoesNotReceiveLaterTargetPublication() async throws {
        let predecessor = try publication()
        let target = try publication()
        try await withPlayingFixture(streaming: true, streamTargetReady: false,
                                     streamPublications: [0: predecessor]) { player, snapshot in
            let pendingID = try await beginPendingSeek(player)
            player.seek(to: 2)
            for _ in 0..<100 {
                if !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let bytes = try Data(contentsOf: XCTUnwrap(player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0)))
            player.enqueueRemoteSegment(data: bytes, jobID: snapshot(false).jobId,
                generation: player.remotePlaybackGeneration, chapterIndex: 1, segmentIndex: 0, publication: target)
            let cancelled = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertTrue(cancelled.records.contains { $0.transition == .cancelled })
            XCTAssertNil(cancelled.streamPublication)
            let completed = try XCTUnwrap(exportedJourneys().last { $0.kind == .seek && $0.id != pendingID })
            XCTAssertTrue(completed.records.contains { $0.transition == .seekTargetReached })
            XCTAssertEqual(completed.streamPublication, predecessor,
                           "A replacement in-chapter seek must correlate its actual retained segment.")
        }
    }

    @MainActor
    func testFullFilePlayerRejectsRemoteSegmentsEvenWithItsCurrentGeneration() async throws {
        let stalePublication = try publication()
        try await withPlayingFixture(streaming: true, streamTargetReady: false) { player, snapshot in
            let bytes = try Data(contentsOf: XCTUnwrap(player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0)))
            player.stop()
            XCTAssertTrue(player.beginRemoteStreaming(snapshot: snapshot(false),
                backendBaseURL: try XCTUnwrap(URL(string: "https://stream-generation.invalid"))))
            let beforeSnapshot = player.remotePlaybackGeneration
            XCTAssertNil(player.testHook_currentPlayerItem())
            player.updateSnapshot(snapshot(true))
            XCTAssertNotEqual(player.remotePlaybackGeneration, beforeSnapshot)
            let replacement = try XCTUnwrap(player.testHook_currentPlayerItem())
            player.enqueueRemoteSegment(data: bytes, jobID: snapshot(true).jobId,
                generation: player.remotePlaybackGeneration, chapterIndex: 0, segmentIndex: 0,
                publication: stalePublication)
            XCTAssertTrue(player.testHook_currentPlayerItem() === replacement)
            XCTAssertEqual(player.testHook_retainedSegmentCount(), 0,
                           "Reopening a remote screen must not append streamed bytes to a full-file player.")
        }
    }

    @MainActor
    func testFullFileReplacementRejectsPreviousRemoteGenerationForSameJob() async throws {
        let stalePublication = try publication()
        try await withPlayingFixture(streaming: true, streamTargetReady: false) { player, snapshot in
            let oldGeneration = player.remotePlaybackGeneration
            let bytes = try Data(contentsOf: XCTUnwrap(player.testHook_segmentURL(chapterIndex: 0, segmentIndex: 0)))
            player.play(snapshot: snapshot(true), startingAt: 1)
            let replacement = try XCTUnwrap(player.testHook_currentPlayerItem())
            player.enqueueRemoteSegment(data: bytes, jobID: snapshot(true).jobId, generation: oldGeneration,
                chapterIndex: 0, segmentIndex: 0, publication: stalePublication)
            XCTAssertTrue(player.testHook_currentPlayerItem() === replacement)
            XCTAssertEqual(player.testHook_retainedSegmentCount(), 0)
            let existing = Set(try exportedJourneys().map(\.id))
            player.seek(to: 2)
            for _ in 0..<100 {
                if !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let journey = try XCTUnwrap(exportedJourneys().first { !existing.contains($0.id) && $0.kind == .seek })
            XCTAssertNil(journey.streamPublication,
                         "A full chapter file must not inherit a previous segment's observation.")
        }
    }
}
#endif
