#if os(iOS) || os(macOS)
import AVFoundation
import XCTest
@testable import EpubToMp3

@MainActor
final class AudioPlayerNavigationPauseTests: XCTestCase {
    func testPreviousDownloadedChapterPreservesPauseDespiteOldPlayingMarker() async throws {
        let id = "navigation-pause-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                          "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                          "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                          "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let savedWidget = widgetKeys.map { widget?.object(forKey: $0) }
        let store = ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults))
        let player = AudioPlayer(resumeStore: store)
        defer {
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(buffer.frameLength))
        let audio = root.appendingPathComponent("chapter.wav")
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        let snapshot = JobSnapshot(jobId: id, state: "finished", bookTitle: "Pause navigation", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil, language: nil,
            progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2,
            chapterProgress: (0...1).map { index in
                .init(index: index, name: "Chapter \(index)", status: "completed",
                      downloadUrl: audio.absoluteString, chars: 100, charsProcessed: 100,
                      progressRatio: 1, durationSeconds: 10, startedAt: nil, completedAt: nil)
            }, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        store.save(jobId: id, chapterIndex: 0, position: 0, wasPlaying: true)
        player.play(snapshot: snapshot, startingAt: 1, restoreAutoplay: false)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentChapterIndex, 1)

        player.previousChapter()

        XCTAssertEqual(player.currentChapterIndex, 0)
        XCTAssertFalse(player.isPlaying, "An explicit paused state must override a previous chapter's old playing marker.")
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
        for _ in 0..<30 where item.status == .unknown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(item.status, .readyToPlay)
        let pausedPosition = player.positionSeconds
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(player.positionSeconds, pausedPosition, accuracy: 0.2)
    }
}
#endif
