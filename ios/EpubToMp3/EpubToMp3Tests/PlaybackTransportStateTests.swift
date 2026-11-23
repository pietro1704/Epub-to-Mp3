import AVFoundation
import Combine
import MediaPlayer
import XCTest
@testable import EpubToMp3

@MainActor
final class PlaybackTransportStateTests: XCTestCase {
    func testSubscribersAgreeAcrossPlayPauseSeekRouteAndJobReplacement() async throws {
        let suite = "transport-state-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = AudioPlayer(location: ReaderLocation(defaults: defaults))
        let media = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).wav")
        try LegacyAudioImportFixture.wave().write(to: media)
        defer {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: media)
        }
        let firstJob = try snapshot(id: "first", file: media)
        let secondJob = try snapshot(id: "second")
        var firstSubscriber: [PlaybackTransportState] = []
        var secondSubscriber: [PlaybackTransportState] = []
        let first = player.transportUpdates.sink { firstSubscriber.append($0) }
        let second = player.transportUpdates.sink { secondSubscriber.append($0) }
        defer { first.cancel(); second.cancel() }

        let playing = try await transition(player, matching: {
            $0.content.job?.jobId == firstJob.jobId && $0.content.isPlaying
        }) {
            player.play(snapshot: firstJob)
            player.resume()
        }
        XCTAssertEqual(playing.content.source, .chapterAudio)
        XCTAssertEqual(playing.content.chapter?.index, 0)
        let retiredQueue = try XCTUnwrap(player.services.queue.player)

        let paused = try await transition(player, matching: { !$0.content.isPlaying }) {
            player.pause()
            player.setRate(.x150)
        }
        XCTAssertEqual(paused.content.rate, .x150)
        XCTAssertEqual(paused.content.generation, playing.content.generation)
        XCTAssertEqual(paused.content.job?.jobId, firstJob.jobId)

        let route = try await transition(player, matching: { $0.content.lastRouteChange == .oldDeviceUnavailable }) {
            player.handlePlaybackRouteChange(reasonRaw: AudioPlayer.RouteChangeReason.oldDeviceUnavailable.rawValue)
        }
        XCTAssertFalse(route.content.isPlaying)
        let nowPlaying = player.makeNowPlayingInfo()
        XCTAssertEqual(nowPlaying[MPMediaItemPropertyTitle] as? String, route.content.chapterTitle)
        XCTAssertEqual((nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.floatValue, 0)

        let waiting = try await transition(player, matching: { $0.content.navigation != nil }) {
            player.play(snapshot: secondJob)
            player.restoreListeningSeek(.init(id: UUID(), jobID: secondJob.jobId, chapterIndex: 0,
                autoplay: false, position: 20), jobID: secondJob.jobId)
        }
        XCTAssertEqual(waiting.content.job?.jobId, secondJob.jobId)
        XCTAssertNotEqual(waiting.content.generation, route.content.generation)
        XCTAssertEqual(waiting.content.navigation?.jobID, secondJob.jobId)
        XCTAssertEqual(waiting.content.navigation?.target, .chapterTime(20))
        XCTAssertEqual(waiting.content.source, .none)
        XCTAssertTrue(waiting.content.isSeeking)
        XCTAssertFalse(waiting.content.isPlaying)
        XCTAssertEqual(waiting.clock.durationSeconds, 0)
        player.services.observation.observePlaybackTime(CMTime(seconds: 42, preferredTimescale: 600), from: retiredQueue)
        XCTAssertEqual(player.captureTransportSample(), waiting.sample)

        XCTAssertEqual(firstSubscriber, secondSubscriber)
        XCTAssertEqual(firstSubscriber.first?.revision, 0)
        XCTAssertTrue(zip(firstSubscriber, firstSubscriber.dropFirst()).allSatisfy {
            $0.revision + 1 == $1.revision
        })
        for state in firstSubscriber {
            if let navigation = state.content.navigation {
                XCTAssertEqual(navigation.jobID, state.content.job?.jobId)
            }
        }
    }

    func testRetiredJobCallbacksCannotRepublishAfterReplacementWithReusedIdentifier() async throws {
        let player = AudioPlayer()
        let host = try XCTUnwrap(URL(string: "http://localhost"))
        let original = try snapshot(id: "reused-id")
        let replacement = try snapshot(id: "replacement")
        XCTAssertTrue(player.beginRemoteStreaming(snapshot: original, backendBaseURL: host))
        let retiredGeneration = try XCTUnwrap(player.remoteSegmentGeneration)

        let committed = try await transition(player, matching: { $0.content.job?.jobId == replacement.jobId }) {
            player.play(snapshot: replacement)
        }
        player.updateSnapshot(original)
        player.finishStreaming(snapshot: original)
        XCTAssertEqual(player.snapshot?.jobId, replacement.jobId)
        XCTAssertEqual(player.transportState, committed)

        let reopened = try await transition(player, matching: { $0.content.job?.jobId == original.jobId }) {
            player.play(snapshot: original)
        }
        XCTAssertNotEqual(reopened.content.generation, retiredGeneration)
        let accepted = await player.enqueueRemoteSegmentAsync(data: LegacyAudioImportFixture.audio,
            jobID: original.jobId, generation: retiredGeneration, chapterIndex: 0, segmentIndex: 0, publication: nil)
        XCTAssertFalse(accepted)
        XCTAssertFalse(player.hasLoadedAudioQueue)
        XCTAssertEqual(player.transportState.content.job?.jobId, original.jobId)
        XCTAssertEqual(player.transportState.content.generation, reopened.content.generation)
    }

    private func transition(_ player: AudioPlayer, matching matches: @escaping (PlaybackTransportState) -> Bool,
                            command: () -> Void) async throws -> PlaybackTransportState {
        let observed = expectation(description: "Committed transport transition")
        let revision = player.transportState.revision
        var result: PlaybackTransportState?
        let subscriber = player.transportUpdates.first { $0.revision > revision && matches($0) }.sink {
            result = $0
            observed.fulfill()
        }
        defer { subscriber.cancel() }
        command()
        await fulfillment(of: [observed], timeout: 5)
        return try XCTUnwrap(result)
    }

    private func snapshot(id: String, file: URL? = nil) throws -> JobSnapshot {
        let chapters = file.map { [["index": 0, "name": "Chapter one", "status": "completed",
                                    "downloadUrl": $0.absoluteString] as [String: Any]] } ?? []
        let json = try JSONSerialization.data(withJSONObject: [
            "jobId": id, "state": file == nil ? "running" : "finished",
            "bookTitle": id, "chapterProgress": chapters, "chapterIndexBase": 0
        ])
        return try JSONDecoder().decode(JobSnapshot.self, from: json)
    }
}
