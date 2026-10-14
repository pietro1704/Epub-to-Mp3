#if os(iOS)
import AVFoundation
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderPagePlaybackChoiceTests: XCTestCase {
    func testPlayAfterTurningPageWhilePausedOffersPageOrContinuation() async throws {
        try await verifyPageChoice()
    }

    func testPageTurnWhilePlayingStillOffersChoiceAfterPause() async throws {
        try await verifyPageChoice(moveBeforePause: true)
    }

    func testUnchangedPagePausePlayResumesWithoutChoice() async throws {
        try await verifyPageChoice(pageRatio: 0, expectsChoice: false)
    }

    func testAnotherReaderBookCannotSeekThePlayingBooksPage() async throws {
        try await verifyPageChoice(expectsChoice: false, changeBook: true)
    }

    private func verifyPageChoice(moveBeforePause: Bool = false, pageRatio: Double = 0.6,
                                  expectsChoice: Bool = true, changeBook: Bool = false) async throws {
        let id = "reader-page-choice-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
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
        let presenter = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer {
            player.stop()
            presenter.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        let audio = root.appendingPathComponent("chapter.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        standard.set(id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.0, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        standard.removeObject(forKey: AudioPlayer.readerCurrentSentenceIdDefaultsKey)
        let chapter = JobSnapshot.Chapter(index: 0, name: "Chapter", status: "completed",
            downloadUrl: audio.absoluteString, chars: 1000, charsProcessed: 1000,
            progressRatio: 1, durationSeconds: 60, startedAt: nil, completedAt: nil)
        let snapshot = JobSnapshot(jobId: id, state: "finished", bookTitle: "Reader page choice",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "fixture", voice: nil,
            language: nil, progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1,
            chapterProgress: [chapter], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        player.play(snapshot: snapshot, restoreAutoplay: false)
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
        for _ in 0..<30 where item.status == .unknown { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        player.resume()
        if moveBeforePause { standard.set(pageRatio, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey) }
        player.pause()
        XCTAssertTrue(player.hasPausedPlaybackToResume)
        standard.set(pageRatio, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        if changeBook { standard.set("another-reader", forKey: ReaderSessionState.currentlyReadingBookIDKey) }

        ReaderPlaybackTapHandler.handle(player: player, presenting: presenter)

        if !expectsChoice {
            XCTAssertNil(presenter.presentedViewController)
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(player.currentChapterIndex, 0)
            if changeBook { XCTAssertFalse(player.isPlaybackForReaderBook("another-reader")) }
            return
        }

        let alert = try XCTUnwrap(presenter.presentedViewController as? UIAlertController,
                                 "Play after a page turn must ask before resuming the old passage.")
        XCTAssertEqual(alert.actions.map(\.title), [
            L10n.string("player.divergence.fromWhereStopped"),
            L10n.string("player.divergence.fromCurrentPage"),
            L10n.string("common.cancel")
        ])
        XCTAssertEqual(alert.actions.last?.style, .cancel)
        XCTAssertFalse(player.isPlaying, "Presenting the choice must leave audio paused.")
    }
}
#endif
