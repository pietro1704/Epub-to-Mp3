#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
@testable import EpubToMp3

final class AudioPlayerPendingSeekTests: XCTestCase {
    @MainActor
    private func withPlayingFixture(
        streaming: Bool = false,
        streamTargetReady: Bool = true,
        streamSegmentCount: Int = 12,
        includeReadyThirdChapter: Bool = false,
        embeddedJob: Bool = false,
        snapshotIndexBase: Int = 0,
        streamPublications: [Int: LatencyObservation.StreamPublication] = [:],
        _ body: (AudioPlayer, (Bool) -> JobSnapshot) async throws -> Void
    ) async throws {
        let identifier = embeddedJob ? UUID().uuidString : "PendingSeek-\(UUID().uuidString)"
        let jobID = embeddedJob ? "embedded-\(identifier)" : identifier
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidgetBook = widgetDefaults?.object(forKey: "currentlyPlayingBookId")
        widgetDefaults?.set("", forKey: "currentlyPlayingBookId")
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier).wav")
        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier)-target.wav")
        let thirdURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(identifier)-third.wav")
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widgetDefaults?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: targetURL)
            try? FileManager.default.removeItem(at: thirdURL)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 8_000)) * 0.01
        }
        do {
            let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
            try file.write(from: buffer)
        }
        try FileManager.default.copyItem(at: audioURL, to: targetURL)
        if includeReadyThirdChapter {
            try FileManager.default.copyItem(at: audioURL, to: thirdURL)
        }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer { player.stop() }
        standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(identifier, forKey: AudioPlayer.currentBookIDDefaultsKey)
        func snapshot(targetReady: Bool) -> JobSnapshot {
            JobSnapshot(
            jobId: jobID, state: targetReady ? "finished" : "running", bookTitle: "Pending seek fixture", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
            progressPercent: targetReady ? 100 : (streaming ? 0 : 50),
            chaptersTotal: includeReadyThirdChapter ? 3 : 2,
            chaptersCompleted: (targetReady ? 2 : (streaming ? 0 : 1)) + (includeReadyThirdChapter ? 1 : 0),
            chapterProgress: [
                .init(index: snapshotIndexBase, name: "Available", status: streaming && !targetReady ? "processing" : "completed",
                      downloadUrl: streaming && !targetReady ? nil : audioURL.absoluteString, chars: 100,
                      charsProcessed: streaming && !targetReady ? 0 : 100,
                      progressRatio: streaming && !targetReady ? 0 : 1, durationSeconds: 15, startedAt: nil, completedAt: nil),
                .init(index: snapshotIndexBase + 1, name: "Pending", status: targetReady ? "completed" : "pending",
                      downloadUrl: targetReady ? targetURL.absoluteString : nil,
                      chars: 100, charsProcessed: targetReady ? 100 : 0,
                      progressRatio: targetReady ? 1 : 0, durationSeconds: targetReady ? 15 : nil,
                      startedAt: nil, completedAt: nil),
            ] + (includeReadyThirdChapter ? [
                .init(index: snapshotIndexBase + 2, name: "Already converted successor", status: "completed",
                      downloadUrl: thirdURL.absoluteString, chars: 100, charsProcessed: 100,
                      progressRatio: 1, durationSeconds: 15, startedAt: nil, completedAt: nil),
            ] : []), outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        }
        if streaming {
            let backend = try XCTUnwrap(URL(string: "https://\(UUID().uuidString.lowercased()).invalid/"))
            XCTAssertTrue(player.beginRemoteStreaming(snapshot: snapshot(targetReady: false), backendBaseURL: backend))
            let data = try Data(contentsOf: audioURL)
            // Place the following chapter beyond the small active queue,
            // requiring file-backed backlog navigation.
            for segment in 0..<streamSegmentCount {
                player.enqueueSegment(data: data, chapterIndex: 0, segmentIndex: segment,
                                      publication: streamPublications[0])
            }
            if streamTargetReady {
                player.enqueueSegment(data: try Data(contentsOf: targetURL), chapterIndex: 1, segmentIndex: 0,
                                      publication: streamPublications[1])
            }
            player.setSegmentChapterEstimate(Double(streamSegmentCount) * 15, forChapterIndex: 0)
            player.setSegmentChapterEstimate(15, forChapterIndex: 1)
        } else {
            player.play(snapshot: snapshot(targetReady: false), startingAt: 0)
        }
        player.resume()
        for _ in 0..<100 {
            if player.positionSeconds > 0 && player.durationSeconds > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(player.positionSeconds, 0, "The available chapter must actually advance.")
        XCTAssertGreaterThan(player.durationSeconds, 0, "Seeking must use the real media duration.")
        do {
            try await body(player, { snapshot(targetReady: $0) })
        } catch {
            player.stop()
            if embeddedJob { try? await LocalAudioArtifactStore.shared.removeAllAudio(bookID: identifier) }
            throw error
        }
        player.stop()
        if embeddedJob { try? await LocalAudioArtifactStore.shared.removeAllAudio(bookID: identifier) }
    }

    @MainActor
    private func exportedJourneys() throws -> [LatencyObservation.Journey] {
        try JSONDecoder().decode([LatencyObservation.Journey].self,
                                 from: LatencyObservationStore.shared.exportData())
    }

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
            player.seek(to: player.durationSeconds)
            let old = try XCTUnwrap(authorize())
            XCTAssertNil(authorize(0))
            player.seek(to: player.durationSeconds)
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

    private func publication() throws -> LatencyObservation.StreamPublication {
        let producer = try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
            """
            {"version":1,"attemptId":"\(UUID().uuidString)","segmentReadyElapsedNanoseconds":40,"artifactPublishedElapsedNanoseconds":55}
            """.utf8))
        return try XCTUnwrap(.init(publicationID: UUID().uuidString, producer: producer))
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
            player.seek(to: player.durationSeconds)
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

    @MainActor
    private func beginPendingSeek(_ player: AudioPlayer) async throws -> UUID {
        let originalIDs = Set(try exportedJourneys().map(\.id))
        player.seek(to: player.durationSeconds)
        try await Task.sleep(nanoseconds: 300_000_000)
        let seeks = try exportedJourneys().filter { !originalIDs.contains($0.id) && $0.kind == .seek }
        XCTAssertEqual(seeks.count, 1)
        let journey = try XCTUnwrap(seeks.first)
        XCTAssertFalse(journey.records.contains { $0.transition == .seekTargetReached })
        XCTAssertTrue(player.isLoading)
        return journey.id
    }

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
    func testSeekToNextStreamedChapterFindsItsFirstSegmentBeyondActiveQueue() async throws {
        try await withPlayingFixture(streaming: true) { player, _ in
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
        try await withPlayingFixture(streaming: true, snapshotIndexBase: 1) { player, _ in
            player.seek(to: player.durationSeconds)
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && player.positionSeconds > 0 && !player.isSeeking { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1,
                           "Remote manifest chapters 1 and 2 must play as segment chapters 0 and 1.")
            XCTAssertTrue(player.isPlaying)
            XCTAssertFalse(player.isSeeking)
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

            player.seek(to: player.durationSeconds)
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

    @MainActor
    private func verifyRepeatedBoundarySeek(pausingBetweenRequests: Bool) async throws {
        try await withPlayingFixture { player, snapshot in
            let firstID = try await beginPendingSeek(player)
            if pausingBetweenRequests { player.pause() }
            let secondID = try await beginPendingSeek(player)
            XCTAssertNotEqual(firstID, secondID)
            let superseded = try XCTUnwrap(exportedJourneys().first { $0.id == firstID })
            XCTAssertTrue(superseded.records.contains { $0.transition == .cancelled })
            XCTAssertFalse(superseded.records.contains { $0.transition == .seekTargetReached })

            player.updateSnapshot(snapshot(true))
            for _ in 0..<100 {
                let reached = try exportedJourneys().contains { journey in
                    journey.id == secondID && journey.records.contains { $0.transition == .seekTargetReached }
                }
                if player.currentChapterIndex == 1 && reached { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertFalse(player.isLoading)
            XCTAssertEqual(player.isPlaying, !pausingBetweenRequests)
            let position = player.positionSeconds
            try await Task.sleep(nanoseconds: 500_000_000)
            if pausingBetweenRequests {
                XCTAssertEqual(player.positionSeconds, position, accuracy: 0.05,
                               "Repeating a seek must not undo an explicit pause.")
            } else {
                XCTAssertGreaterThan(player.positionSeconds, position,
                                     "Repeating a waiting seek must retain autoplay intent.")
            }
            let completed = try XCTUnwrap(exportedJourneys().first { $0.id == secondID })
            XCTAssertEqual(completed.records.filter { $0.transition == .seekTargetReached }.count, 1)
            XCTAssertFalse(completed.records.contains { $0.transition == .cancelled })
        }
    }

    @MainActor
    func testPendingPlayerNavigationPrioritizesConversionUntilArrival() async throws {
        try await withPlayingFixture(embeddedJob: true) { player, snapshot in
            let bookID = try XCTUnwrap(EmbeddedConversionCoordinator.embeddedBookID(from: snapshot(false).jobId))
            let scheduler = LocalAudioConversionScheduler(initialConnectivity: .wifi, observesNetwork: false)
            scheduler.prioritize(bookID: bookID, chapterIndices: [2])
            let binding = PendingPlaybackNavigationBinding(player: player, bookID: bookID, scheduler: scheduler)
            defer { binding.invalidate() }
            _ = try await beginPendingSeek(player)
            XCTAssertEqual(scheduler.nextChapterIndex(bookID: bookID, available: [0, 1, 2],
                                                      defaultOrder: [0, 1, 2]), 1)
            player.updateSnapshot(snapshot(true))
            for _ in 0..<100 {
                if player.currentChapterIndex == 1 && !player.isLoading { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertFalse(player.isLoading)
            XCTAssertEqual(scheduler.nextChapterIndex(bookID: bookID, available: [0, 1, 2],
                                                      defaultOrder: [0, 1, 2]), 2,
                           "Completed navigation must restore the normal priority queue.")
        }
    }

    @MainActor
    func testStoppingPlayerClearsBoundConversionPriority() async throws {
        try await verifyBoundPriorityCleanup(invalidateBinding: false)
    }

    @MainActor
    func testInvalidatingBindingClearsOnlyItsPendingPriority() async throws {
        try await verifyBoundPriorityCleanup(invalidateBinding: true)
    }

    @MainActor
    private func verifyBoundPriorityCleanup(invalidateBinding: Bool) async throws {
        try await withPlayingFixture(embeddedJob: true) { player, snapshot in
            let bookID = try XCTUnwrap(EmbeddedConversionCoordinator.embeddedBookID(from: snapshot(false).jobId))
            let scheduler = LocalAudioConversionScheduler(initialConnectivity: .wifi, observesNetwork: false)
            scheduler.prioritize(bookID: bookID, chapterIndices: [2])
            let binding = PendingPlaybackNavigationBinding(player: player, bookID: bookID, scheduler: scheduler)
            defer { binding.invalidate() }
            _ = try await beginPendingSeek(player)
            XCTAssertEqual(scheduler.nextChapterIndex(bookID: bookID, available: [0, 1, 2],
                                                      defaultOrder: [0, 1, 2]), 1)
            if invalidateBinding { binding.invalidate() } else { player.stop() }
            XCTAssertEqual(scheduler.nextChapterIndex(bookID: bookID, available: [0, 1, 2],
                                                      defaultOrder: [0, 1, 2]), 2)
        }
    }

    @MainActor
    func testPendingPlayerNavigationDoesNotPrioritizeAnotherBook() async throws {
        try await withPlayingFixture(embeddedJob: true) { player, _ in
            let otherBookID = UUID().uuidString
            let scheduler = LocalAudioConversionScheduler(initialConnectivity: .wifi, observesNetwork: false)
            scheduler.prioritize(bookID: otherBookID, chapterIndices: [2])
            let binding = PendingPlaybackNavigationBinding(player: player, bookID: otherBookID, scheduler: scheduler)
            defer { binding.invalidate() }
            _ = try await beginPendingSeek(player)
            XCTAssertEqual(scheduler.nextChapterIndex(bookID: otherBookID, available: [0, 1, 2],
                                                      defaultOrder: [0, 1, 2]), 2)
        }
    }

    @MainActor
    func testNavigationRequestedDuringResourceWaitWinsNextConversionBoundary() async throws {
        try await withPlayingFixture(embeddedJob: true) { player, snapshot in
            let completedSnapshot = snapshot(true)
            let bookID = try XCTUnwrap(EmbeddedConversionCoordinator.embeddedBookID(from: completedSnapshot.jobId))
            let scheduler = LocalAudioConversionScheduler(initialConnectivity: .wifi, observesNetwork: false)
            let binding = PendingPlaybackNavigationBinding(player: player, bookID: bookID, scheduler: scheduler)
            defer { binding.invalidate(); scheduler.setResourceConstraint(.stable) }
            scheduler.setResourceConstraint(.thermalPressure)
            var boundaryStarted = false
            var selectedChapter: Int?
            var boundaryFinished = false
            let conversion = Task { @MainActor in
                try await scheduler.submit(bookID: bookID, requiresWiFi: true,
                                           priorityChapterIndices: [2], coalescingKey: "resource-boundary") {
                    boundaryStarted = true
                    selectedChapter = try await EmbeddedConversionCoordinator.nextReadyChapterIndex(
                        bookID: bookID, available: [0, 1, 2], defaultOrder: [0, 1, 2], scheduler: scheduler)
                    boundaryFinished = true
                    return completedSnapshot
                }
            }
            defer { conversion.cancel() }
            for _ in 0..<100 {
                if boundaryStarted { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(boundaryStarted)
            XCTAssertFalse(boundaryFinished, "Thermal pressure must suspend the actual conversion boundary.")
            XCTAssertNil(selectedChapter)
            _ = try await beginPendingSeek(player)
            XCTAssertFalse(boundaryFinished, "A pending navigation must not bypass the resource gate.")
            scheduler.setResourceConstraint(.stable)
            _ = try await conversion.value
            XCTAssertTrue(boundaryFinished)
            XCTAssertEqual(selectedChapter, 1,
                           "Select after resource recovery so navigation arriving during the wait wins over priority 2.")
        }
    }

    @MainActor
    func testAcceptedPlaybackAfterResourceWaitClearsStaleNavigationBeforeSelection() async throws {
        try await withPlayingFixture(embeddedJob: true) { player, snapshot in
            let replacementSnapshot = snapshot(true)
            let bookID = try XCTUnwrap(EmbeddedConversionCoordinator.embeddedBookID(from: replacementSnapshot.jobId))
            let scheduler = LocalAudioConversionScheduler(initialConnectivity: .wifi, observesNetwork: false)
            let binding = PendingPlaybackNavigationBinding(player: player, bookID: bookID, scheduler: scheduler)
            defer { binding.invalidate(); scheduler.setResourceConstraint(.stable) }
            let pendingID = try await beginPendingSeek(player)
            scheduler.setResourceConstraint(.thermalPressure)
            var boundaryStarted = false
            var selectedChapter: Int?
            let conversion = Task { @MainActor in
                try await scheduler.submit(bookID: bookID, requiresWiFi: true,
                                           priorityChapterIndices: [2], coalescingKey: "replacement-boundary") {
                    boundaryStarted = true
                    selectedChapter = try await EmbeddedConversionCoordinator.nextReadyChapterIndex(
                        bookID: bookID, available: [0, 1, 2], defaultOrder: [0, 1, 2], scheduler: scheduler,
                        prepareSelection: {
                            player.play(snapshot: replacementSnapshot, startingAt: 0)
                        })
                    return replacementSnapshot
                }
            }
            defer { conversion.cancel() }
            for _ in 0..<100 {
                if boundaryStarted { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(boundaryStarted)
            XCTAssertNil(selectedChapter)
            XCTAssertTrue(player.isLoading)
            let waiting = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertFalse(waiting.records.contains { $0.transition == .cancelled },
                           "The old navigation stays pending while playback acceptance awaits resource recovery.")

            scheduler.setResourceConstraint(.stable)
            _ = try await conversion.value

            XCTAssertEqual(selectedChapter, 2,
                           "Accepted replacement playback must clear stale chapter 1 before choosing conversion work.")
            XCTAssertEqual(player.currentChapterIndex, 0)
            let superseded = try XCTUnwrap(exportedJourneys().first { $0.id == pendingID })
            XCTAssertTrue(superseded.records.contains { $0.transition == .cancelled })
            XCTAssertFalse(superseded.records.contains { $0.transition == .seekTargetReached })
        }
    }
}
#endif
