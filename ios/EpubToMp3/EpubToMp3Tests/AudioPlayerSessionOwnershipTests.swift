#if os(iOS)
import AVFoundation
import Foundation
import XCTest
@testable import EpubToMp3

final class AudioPlayerSessionOwnershipTests: XCTestCase {
    @MainActor
    func testReleasingPreviousPlayerDoesNotPreventCurrentPlayerFromResuming() async throws {
        let identifier = "SessionOwnership-\(UUID().uuidString)"
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
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widgetDefaults?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: audioURL)
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

        func snapshot(_ suffix: String) -> JobSnapshot {
            JobSnapshot(
                jobId: "\(identifier)-\(suffix)", state: "finished", bookTitle: "Session ownership fixture",
                bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
                progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
                chapterProgress: [.init(index: 0, name: "Chapter", status: "completed",
                    downloadUrl: audioURL.absoluteString, chars: 100, charsProcessed: 100,
                    progressRatio: 1, durationSeconds: 15, startedAt: nil, completedAt: nil)],
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        }
        func selectBook(_ suffix: String) {
            standard.set("\(identifier)-\(suffix)", forKey: ReaderSessionState.currentlyReadingBookIDKey)
            standard.set("\(identifier)-\(suffix)", forKey: AudioPlayer.currentBookIDDefaultsKey)
        }

        var previous: AudioPlayer? = AudioPlayer(
            resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        weak var releasedPlayer = previous
        let current = AudioPlayer(
            resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            previous?.stop()
            current.stop()
        }
        selectBook("previous")
        previous?.play(snapshot: snapshot("previous"), startingAt: 0)
        previous?.resume()
        guard try await requireAdvancement(XCTUnwrap(previous), after: 0, phase: "Previous player initial playback") else {
            return
        }
        previous?.pause()

        selectBook("current")
        current.play(snapshot: snapshot("current"), startingAt: 0)
        current.resume()
        guard try await requireAdvancement(current, after: 0, phase: "Current player initial playback") else {
            return
        }
        current.pause()
        let item = try XCTUnwrap(current.testHook_currentPlayerItem())

        // Both players have activated the process-wide session, but only the
        // surviving player owns the next explicit playback request.
        previous = nil
        for _ in 0..<100 {
            if releasedPlayer == nil { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(releasedPlayer, "The previous player's actual deinit must run before resuming its successor.")
        guard releasedPlayer == nil else { return }
        let pausedTime = item.currentTime().seconds
        XCTAssertTrue(pausedTime.isFinite)
        current.resume()
        XCTAssertTrue(current.testHook_currentPlayerItem() === item,
                      "Resuming must retain the current chapter's real media item.")
        _ = try await requireAdvancement(current, after: pausedTime,
                                        phase: "Current player resume after previous player deinit")
    }

    @MainActor
    private func requireAdvancement(_ player: AudioPlayer, after baseline: Double, phase: String) async throws -> Bool {
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
        for _ in 0..<100 {
            if item.currentTime().seconds > baseline + 0.2 { return true }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("\(phase): media time did not advance from \(baseline); current=\(item.currentTime().seconds), "
                + "published=\(player.positionSeconds), isPlaying=\(player.isPlaying), status=\(item.status.rawValue), "
                + "error=\(String(describing: item.error)), sessionRate=\(AVAudioSession.sharedInstance().sampleRate)")
        return false
    }
}
#endif
