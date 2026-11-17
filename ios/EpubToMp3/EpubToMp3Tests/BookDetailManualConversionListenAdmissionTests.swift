#if os(macOS)
import XCTest
import AVFoundation
import AppKit

@testable import EpubToMp3

extension BookDetailManualConversionTests {
    func testMacListenRoutesThroughStreamingExecutor() async throws {
        let id = "detail-streaming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try EpubFixture.createWithChapter(body: "A fixture for the Mac Listen action.")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   importDirectory: root.appendingPathComponent("imports"))
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let streamingStarted = expectation(description: "Listen invokes the streaming conversion pipeline")
        var manualExecutorCalled = false
        var chunkCallbackWasProvided = false
        let playbackKeys = [AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let savedPlayback = playbackKeys.map { UserDefaults.standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetBook = widgetDefaults?.object(forKey: "currentlyPlayingBookId")
        defer {
            player.stop()
            for (key, value) in zip(playbackKeys, savedPlayback) {
                restoreMac(value, forKey: key, in: .standard)
            }
            restoreOptionalMac(widgetBook, forKey: "currentlyPlayingBookId", in: widgetDefaults)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let controller = MacBookDetailViewController(
            book: book, library: library, settings: AppSettings(defaults: defaults),
            player: player, playerPresentation: presentation, onRead: { _ in }, onShowJobs: {},
            conversionExecutor: { _, jobID, _, _, _, _, _ in
                manualExecutorCalled = true
                let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                    "jobId": jobID, "title": "Listen fixture", "author": "Author", "chapters": []
                ]])
                return .init(jobID: jobID, manifestJSON: manifest, outputDirectory: root)
            },
            streamingExecutor: { _, jobID, start, end, _, options, _, _, chunk in
                XCTAssertEqual(end, -1)
                XCTAssertEqual(options?.engine, "edge")
                chunkCallbackWasProvided = chunk != nil
                streamingStarted.fulfill()
                let segment = Data([0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0, count: 508))
                try segment.write(to: root.appendingPathComponent("chapter.mp3"))
                let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                    "jobId": jobID, "title": "Listen fixture", "author": "Author", "chapters": [[
                        "title": "Chapter", "filename": "chapter.mp3", "textChars": 32,
                        "sourceIndex": Int(start)
                    ]]
                ]])
                return .init(jobID: jobID, manifestJSON: manifest, outputDirectory: root)
            }
        )
        _ = controller.view
        let listenButton = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.string("bookDetail.listenStart") })

        listenButton.performClick(nil)

        await fulfillment(of: [streamingStarted], timeout: 3)
        XCTAssertFalse(manualExecutorCalled, "Listen must not wait for whole chapter callbacks.")
        XCTAssertTrue(chunkCallbackWasProvided, "Listen must provide Rust with its audio chunk delivery callback.")
        withExtendedLifetime(controller) { }
    }
}
#endif
