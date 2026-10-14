#if os(iOS)
import AVFoundation
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class IOSRootPlaybackRestorationTests: XCTestCase {
    func testStartupRestoresCurrentReaderInsteadOfStalePlayingBook() async throws {
        let id = "root-restore-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
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
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let oldSource = try EpubFixture.createWithChapters(["Old book first.", "Old book second."])
        let currentSource = try EpubFixture.createWithChapters(["Current reader first.", "Current reader second."])
        let oldBook = try library.importBook(from: oldSource)
        let currentBook = try library.importBook(from: currentSource)
        let oldJob = "\(id)-old"
        let currentJob = "\(id)-current"
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let conversions = support.appendingPathComponent("EpubToMp3/RustConversions")
        let previousKeyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        defer {
            player.stop()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: id)
            for job in [oldJob, currentJob] { try? FileManager.default.removeItem(at: conversions.appendingPathComponent(job)) }
            for url in [root, oldSource, currentSource] { try? FileManager.default.removeItem(at: url) }
        }
        for job in [oldJob, currentJob] {
            let directory = conversions.appendingPathComponent(job)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 40_000))
            buffer.frameLength = buffer.frameCapacity
            try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(buffer.frameLength))
            do {
                let file = try AVAudioFile(forWriting: directory.appendingPathComponent("chapter.wav"), settings: format.settings)
                try file.write(from: buffer)
            }
            let manifest: [String: Any] = ["jobId": job, "title": job, "author": "Author",
                "chapters": (0...1).map { ["title": "Chapter \($0)", "filename": "chapter.wav", "textChars": 20, "sourceIndex": $0] }]
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
        }
        library.recordConversion(jobId: oldJob, for: oldBook.id)
        library.recordConversion(jobId: currentJob, for: currentBook.id)
        standard.set(currentBook.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(oldBook.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        widget?.set(oldBook.id, forKey: "currentlyPlayingBookId")
        standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        let controller = IOSRootContainerController(settings: AppSettings(defaults: defaults), library: library,
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while player.snapshot == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(player.snapshot?.jobId, currentJob,
                       "A stale playing pointer must not reinstall another book over the restored reader.")
        XCTAssertFalse(player.isPlaying, "Startup restoration must preserve pause.")
        XCTAssertEqual(player.snapshot?.playableChapters.count, 2)
        withExtendedLifetime(controller) { }
    }
}
#endif
