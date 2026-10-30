#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import EpubToMp3

final class AudioPlayerPendingSeekTests: XCTestCase {
    @MainActor
    func withPlayingFixture(
        streaming: Bool = false,
        streamTargetReady: Bool = true,
        streamSegmentCount: Int = 12,
        streamCurrentComplete: Bool = false,
        providesStreamEstimates: Bool = true,
        includeReadyThirdChapter: Bool = false,
        embeddedJob: Bool = false,
        snapshotIndexBase: Int = 0,
        streamPublications: [Int: LatencyObservation.StreamPublication] = [:],
        afterResume: @MainActor () -> Void = {},
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
                .init(index: snapshotIndexBase, name: "Available", status: streaming && !targetReady && !streamCurrentComplete ? "processing" : "completed",
                      downloadUrl: streaming && !targetReady ? nil : audioURL.absoluteString, chars: 100,
                      charsProcessed: streaming && !targetReady ? 0 : 100,
                      progressRatio: streaming && !targetReady ? 0 : 1,
                      durationSeconds: streaming && !targetReady && streamCurrentComplete ? Double(streamSegmentCount) * 15 : 15,
                      startedAt: nil, completedAt: nil),
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
            if providesStreamEstimates {
                player.setSegmentChapterEstimate(Double(streamSegmentCount) * 15, forChapterIndex: 0)
                player.setSegmentChapterEstimate(15, forChapterIndex: 1)
            }
        } else {
            player.play(snapshot: snapshot(targetReady: false), startingAt: 0)
        }
        player.resume()
        afterResume()
        let expectsChapterDuration = !streaming || providesStreamEstimates || streamCurrentComplete
        for _ in 0..<100 {
            let mediaDuration = player.testHook_currentPlayerItem()?.duration.seconds ?? 0
            if player.positionSeconds > 0 && mediaDuration > 0
                && (!expectsChapterDuration || player.durationSeconds > 0) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let initialItem = player.testHook_currentPlayerItem()
        let initialError = initialItem?.error as NSError?
        XCTAssertGreaterThan(player.positionSeconds, 0,
            "The available chapter must actually advance. "
            + "itemTime=\(initialItem?.currentTime().seconds ?? -1) status=\(initialItem?.status.rawValue ?? -1) "
            + "playing=\(player.isPlaying) duration=\(player.durationSeconds) "
            + "error=\(initialError?.domain ?? "none"):\(initialError?.code ?? 0)")
        XCTAssertGreaterThan(initialItem?.duration.seconds ?? 0, 0, "The playing media must have a real duration.")
        if expectsChapterDuration {
            XCTAssertGreaterThan(player.durationSeconds, 0, "The chapter duration must be available for this fixture.")
        }
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
    func exportedJourneys() throws -> [LatencyObservation.Journey] {
        try JSONDecoder().decode([LatencyObservation.Journey].self,
                                 from: LatencyObservationStore.shared.exportData())
    }

    @MainActor
    func waitForNavigation(_ player: AudioPlayer) async throws {
        for _ in 0..<100 {
            if !player.isSeeking { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(player.isSeeking, "Navigation must finish against real media.")
        XCTAssertNil(player.pendingNavigation)
    }


    #if os(iOS)
    #endif









    #if os(iOS)
    #endif




    @MainActor
    func verifyLateEndConfirmation(finalFile: Bool, confirmImmediately: Bool = false) async throws {
        try await withPlayingFixture(streaming: true) { player, snapshot in
            player.pause()
            player.nextChapter()
            try await self.waitForNavigation(player)
            if confirmImmediately { player.resume() }
            let previous = Set(try self.exportedJourneys().map(\.id))
            player.seek(to: 35)
            if !confirmImmediately { try await Task.sleep(nanoseconds: 100_000_000) }
            let pending = try XCTUnwrap(player.pendingNavigation)
            XCTAssertEqual(pending.chapterIndex, 1)
            XCTAssertEqual(player.positionSeconds, 35, accuracy: 0.1)
            let requested = try XCTUnwrap(self.exportedJourneys().first { !previous.contains($0.id) && $0.kind == .seek })
            if finalFile { player.finishStreaming(snapshot: snapshot(true)) }
            else { player.updateSnapshot(snapshot(true)) }
            if confirmImmediately { player.pause() }
            try await self.waitForNavigation(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertEqual(player.positionSeconds, 15, accuracy: 0.1)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 15, accuracy: 0.1)
            XCTAssertFalse(player.isPlaying)
            let completed = try XCTUnwrap(self.exportedJourneys().first { $0.id == requested.id })
            XCTAssertFalse(completed.records.contains { $0.transition == .cancelled })
            XCTAssertEqual(completed.records.filter { $0.transition == .seekTargetReached }.count, 1)
        }
    }












    func publication() throws -> LatencyObservation.StreamPublication {
        let producer = try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
            """
            {"version":1,"attemptId":"\(UUID().uuidString)","segmentReadyElapsedNanoseconds":40,"artifactPublishedElapsedNanoseconds":55}
            """.utf8))
        return try XCTUnwrap(.init(publicationID: UUID().uuidString, producer: producer))
    }







    @MainActor
    func beginPendingSeek(_ player: AudioPlayer) async throws -> UUID {
        let originalIDs = Set(try exportedJourneys().map(\.id))
        if player.testHook_activeSegmentIdentity() != nil { player.nextChapter() }
        else { player.seek(to: player.durationSeconds) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let seeks = try exportedJourneys().filter { !originalIDs.contains($0.id) && $0.kind == .seek }
        XCTAssertEqual(seeks.count, 1)
        let journey = try XCTUnwrap(seeks.first)
        XCTAssertFalse(journey.records.contains { $0.transition == .seekTargetReached })
        XCTAssertTrue(player.isLoading)
        return journey.id
    }















    @MainActor
    func verifyRepeatedBoundarySeek(pausingBetweenRequests: Bool) async throws {
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


}
#endif
