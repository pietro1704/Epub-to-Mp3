#if os(iOS) || os(macOS)
import XCTest
import AVFoundation
#if os(macOS)
import AppKit
#endif

@testable import EpubToMp3

extension BookDetailManualConversionTests {
#if os(iOS)
    func testListenUsesStreamingExecutorInsteadOfWholeBookConversion() async throws {
        let id = "detail-listen-streaming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try EpubFixture.createWithChapter(body: "Listen should stream this chapter.")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   importDirectory: root.appendingPathComponent("imports"))
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let started = expectation(description: "Listen enters one conversion executor")
        var conversionCalled = false
        var streamingCalled = false
        var pendingPlaybackInstalled = false
        let playbackKeys = [AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let savedPlayback = playbackKeys.map { UserDefaults.standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                          "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                          "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                          "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let savedWidget = widgetKeys.map { widgetDefaults?.object(forKey: $0) }
        defer {
            player.stop()
            for (key, value) in zip(playbackKeys, savedPlayback) {
                restore(value, forKey: key, in: .standard)
            }
            if let widgetDefaults {
                for (key, value) in zip(widgetKeys, savedWidget) {
                    restore(value, forKey: key, in: widgetDefaults)
                }
            }
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        func result(jobID: String) throws -> RustConversionCoordinator.Result {
            let manifest = ["manifest": [
                "jobId": jobID, "title": book.resolvedTitle, "author": book.author ?? "",
                "chapters": [["title": "Chapter", "filename": "chapter.wav",
                              "textChars": 32, "sourceIndex": 0]],
            ]] as [String: Any]
            return .init(jobID: jobID,
                         manifestJSON: try JSONSerialization.data(withJSONObject: manifest),
                         outputDirectory: root)
        }

        let settings = AppSettings(defaults: defaults)
        let controller = BookDetailScreenController(
            book: book, library: library, settings: settings,
            player: player, playerPresentation: presentation,
            conversionExecutor: { _, jobID, _, _, _, _, _ in
                conversionCalled = true
                started.fulfill()
                return try result(jobID: jobID)
            },
            streamingExecutor: { _, jobID, chapterStart, chapterEnd, _, options, _, _, chunk in
                streamingCalled = true
                XCTAssertEqual(chapterStart, 0)
                XCTAssertEqual(chapterEnd, -1, "Listen streams from the requested chapter onward.")
                XCTAssertEqual(options?.engine, "edge")
                XCTAssertEqual(options?.ttsPreferences?.primary.engine, "edge",
                               "Listen must preserve the preferences captured before opening the book.")
                XCTAssertEqual(player.snapshot?.engine, "edge")
                XCTAssertNotNil(chunk, "Listen must supply the incremental audio callback.")
                pendingPlaybackInstalled = player.snapshot?.jobId == jobID && player.isConverting
                started.fulfill()
                return try result(jobID: jobID)
            },
            bookFileOpener: { _ in
                settings.audioEngine = .piper
                return source
            }
        )
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "bookDetail.listen" })
        button.sendActions(for: .touchUpInside)

        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(streamingCalled, "Listen must use the streaming executor.")
        XCTAssertFalse(conversionCalled, "Whole-book conversion belongs to Download/Convert.")
        XCTAssertTrue(pendingPlaybackInstalled, "The pending streaming session must be installed before conversion starts.")
        withExtendedLifetime(controller) { }
    }
#endif

#if os(iOS)
    func testListenIgnoresRepeatedTapWhileBookURLIsOpening() async throws {
        let id = "detail-listen-single-flight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try EpubFixture.createWithChapter(body: "Listen opens this book only once.")
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   importDirectory: root.appendingPathComponent("imports"))
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let openStarted = expectation(description: "First Listen reserves its request before opening")
        var openContinuation: CheckedContinuation<URL, Error>?
        var openCount = 0
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidget = widgetDefaults?.object(forKey: "currentlyPlayingBookId")
        defer {
            openContinuation?.resume(throwing: CancellationError())
            player.stop()
            restoreOptional(savedWidget, forKey: "currentlyPlayingBookId", in: widgetDefaults)
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        let controller = BookDetailScreenController(
            book: book, library: library, settings: AppSettings(defaults: defaults),
            player: player, playerPresentation: presentation,
            bookFileOpener: { _ in
                openCount += 1
                openStarted.fulfill()
                return try await withCheckedThrowingContinuation { openContinuation = $0 }
            }
        )
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "bookDetail.listen" })
        button.sendActions(for: .touchUpInside)
        await fulfillment(of: [openStarted], timeout: 3)
        button.sendActions(for: .touchUpInside)
        await Task.yield()

        XCTAssertEqual(openCount, 1, "A pending Listen request must ignore repeated taps.")
        openContinuation?.resume(throwing: CancellationError())
        openContinuation = nil
        withExtendedLifetime(controller) { }
    }
#endif

#if os(macOS)
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
#endif

#if os(iOS)
    func testBookDetailActionsKeepMainActorResponsiveWhileOpeningBook() async throws {
        try await verifyBookDetailOpenIsAsynchronous(actionIdentifier: "bookDetail.listen")
        try await verifyBookDetailOpenIsAsynchronous(actionIdentifier: "bookDetail.download")
    }
#endif
}
#endif
