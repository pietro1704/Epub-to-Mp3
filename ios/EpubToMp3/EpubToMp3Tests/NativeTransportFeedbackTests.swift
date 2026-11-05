#if os(iOS)
import AVFoundation
import UIKit
import XCTest
@testable import EpubToMp3

/// Real AVQueuePlayer and UIKit commands, with silent local WAVs and isolated
/// stores. No conversion, provider, download or user library reset is involved.
@MainActor
final class NativeTransportFeedbackTests: XCTestCase {
    private func fixture(_ body: (AudioPlayer, UserDefaults) async throws -> Void) async throws {
        let id = "transport-feedback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
            AudioPlayer.currentChapterIndexDefaultsKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
            AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
            "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
            "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
            "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let savedWidget = widgetKeys.map { widget?.object(forKey: $0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        widget?.set("", forKey: "currentlyPlayingBookId")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(buffer.frameLength))
        let paths = (0..<2).map { root.appendingPathComponent("chapter-\($0).wav") }
        for url in paths {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let snapshot = JobSnapshot(jobId: id, state: "finished", bookTitle: "Silent transport fixture", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
            progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2,
            chapterProgress: paths.enumerated().map { index, url in
                .init(index: index, name: "Chapter \(index)", status: "completed", downloadUrl: url.absoluteString,
                    chars: 100, charsProcessed: 100, progressRatio: 1, durationSeconds: 60,
                    startedAt: nil, completedAt: nil)
            }, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        player.play(snapshot: snapshot, startingAt: 0, restoreAutoplay: false)
        try await ready(player)
        try await body(player, defaults)
    }

    private func ready(_ player: AudioPlayer) async throws {
        for _ in 0..<100 {
            if player.testHook_currentPlayerItem()?.status == .readyToPlay && !player.isSeeking { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Local silent item did not become ready")
        throw NSError(domain: "TransportFeedback", code: 1)
    }

    private func seek(_ player: AudioPlayer, to seconds: Double) async throws {
        player.seek(to: seconds)
        try await ready(player)
        XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, seconds, accuracy: 0.15)
        XCTAssertEqual(player.positionSeconds, seconds, accuracy: 0.15)
    }

    func testFifteenSecondCommandsAndChapterBoundariesPreservePause() async throws {
        try await fixture { player, _ in
            try await seek(player, to: 30)
            player.skipBackward(seconds: 15)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(player.positionSeconds, 15, accuracy: 0.2)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 15, accuracy: 0.2)
            player.skipForward(seconds: 15)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(player.positionSeconds, 30, accuracy: 0.2)
            try await seek(player, to: 5)
            player.skipBackward(seconds: 15)
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(player.positionSeconds, 0, accuracy: 0.2)
            player.previousChapter()
            XCTAssertEqual(player.currentChapterIndex, 0)
            player.nextChapter()
            try await ready(player)
            XCTAssertEqual(player.currentChapterIndex, 1)
            player.nextChapter()
            XCTAssertEqual(player.currentChapterIndex, 1, "Last chapter cannot navigate beyond the catalog")
            player.previousChapter()
            try await ready(player)
            XCTAssertEqual(player.currentChapterIndex, 0)
            XCTAssertFalse(player.isPlaying)
        }
    }

    func testExpandedSliderCommitsArbitraryPositionAndLatestSeekWins() async throws {
        try await fixture { player, defaults in
            let controller = FullPlayerScreenController(player: player, playbackClock: player.playbackClock,
                library: LibraryStore(defaults: defaults), playerPresentation: PlayerPresentation(defaults: defaults),
                settings: AppSettings(defaults: defaults), onStartListening: {})
            controller.loadViewIfNeeded()
            func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
            let slider = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? CompactSlider }.first)
            // AVPlayer readiness can precede the duration KVO reaching the UI.
            // A user cannot scrub the disabled, initial 0...1 control.
            for _ in 0..<100 where !slider.isEnabled || slider.maximumValue < 59.9 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(slider.isEnabled)
            XCTAssertGreaterThanOrEqual(slider.maximumValue, 59.9)
            slider.sendActions(for: .touchDown)
            slider.value = 23.75
            slider.sendActions(for: .valueChanged)
            slider.sendActions(for: .touchUpInside)
            try await ready(player)
            XCTAssertEqual(player.positionSeconds, 23.75, accuracy: 0.15)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 23.75, accuracy: 0.15)
            player.seek(to: 12)
            player.seek(to: 42.5)
            try await ready(player)
            XCTAssertEqual(player.positionSeconds, 42.5, accuracy: 0.15)
            XCTAssertEqual(try XCTUnwrap(player.testHook_currentPlayerItem()).currentTime().seconds, 42.5, accuracy: 0.15)
            XCTAssertEqual(slider.value, 42.5, accuracy: 0.15)
            XCTAssertFalse(player.isPlaying, "A paused slider must not start audio")
        }
    }

    func testConfirmedOutputDisappearsImmediatelyOnPauseAndSeek() async throws {
        try await fixture { player, _ in
            player.resume()
            for _ in 0..<40 where player.playbackClock.audioOutput.position == nil {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertNotNil(player.playbackClock.audioOutput.position, "Real AVFoundation cursor must advance")
            player.pause()
            XCTAssertNil(player.playbackClock.audioOutput.position)
            try await seek(player, to: 20)
            XCTAssertNil(player.playbackClock.audioOutput.position)
            XCTAssertFalse(player.isPlaying)
        }
    }
}
#endif
