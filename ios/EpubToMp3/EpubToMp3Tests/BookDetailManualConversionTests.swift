#if os(iOS) || os(macOS)
import XCTest
import AVFoundation
@testable import EpubToMp3

@MainActor
final class BookDetailManualConversionTests: XCTestCase {
    func testManualCompletionPreservesExistingPlaybackSession() async throws {
        try await verifyManualConversion(existingSession: true)
    }

    func testManualCompletionDoesNotCreatePlaybackSession() async throws {
        try await verifyManualConversion(existingSession: false)
    }

    #if os(iOS)
    func testBookDetailActionsKeepMainActorResponsiveWhileOpeningBook() async throws {
        try await verifyBookDetailOpenIsAsynchronous(actionIdentifier: "bookDetail.listen")
        try await verifyBookDetailOpenIsAsynchronous(actionIdentifier: "bookDetail.download")
    }

    private func verifyBookDetailOpenIsAsynchronous(actionIdentifier: String) async throws {
        let id = "detail-open-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try EpubFixture.create()
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   importDirectory: root.appendingPathComponent("imports"))
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let openStarted = expectation(description: "Book Detail awaits asynchronous bookmark resolution")
        let mainActorHeartbeat = expectation(description: "MainActor remains responsive during bookmark resolution")
        let conversionStarted = expectation(description: "Conversion starts after the book URL resolves")
        var openContinuation: CheckedContinuation<URL, Error>?
        var didStartOpen = false
        let playbackKeys = [AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let savedPlayback = playbackKeys.map { UserDefaults.standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetPlaybackKeys = [
            "currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
            "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
            "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
            "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"
        ]
        let savedWidgetPlayback = widgetPlaybackKeys.map { widgetDefaults?.object(forKey: $0) }
        defer {
            openContinuation?.resume(throwing: CancellationError())
            player.stop()
            for (key, value) in zip(playbackKeys, savedPlayback) {
                restore(value, forKey: key, in: .standard)
            }
            if let widgetDefaults {
                for (key, value) in zip(widgetPlaybackKeys, savedWidgetPlayback) {
                    restore(value, forKey: key, in: widgetDefaults)
                }
            }
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let executor: RustConversionCoordinator.Executor = { url, job, _, _, _, _ in
            XCTAssertEqual(url.lastPathComponent, source.lastPathComponent)
            conversionStarted.fulfill()
            let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                "jobId": job, "title": "Opened book", "chapters": []
            ]])
            return .init(jobID: job, manifestJSON: manifest, outputDirectory: root)
        }
        let controller = BookDetailScreenController(
            book: book, library: library, settings: AppSettings(defaults: defaults),
            player: player, playerPresentation: presentation, conversionExecutor: executor,
            bookFileOpener: { requestedID in
                XCTAssertEqual(requestedID, book.id)
                didStartOpen = true
                openStarted.fulfill()
                return try await withCheckedThrowingContinuation { openContinuation = $0 }
            })
        controller.loadViewIfNeeded()
        let button = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == actionIdentifier })
        button.sendActions(for: .touchUpInside)
        await fulfillment(of: [openStarted], timeout: 3)
        guard didStartOpen else { return }
        Task { @MainActor in mainActorHeartbeat.fulfill() }
        await fulfillment(of: [mainActorHeartbeat], timeout: 1)
        openContinuation?.resume(returning: source)
        openContinuation = nil
        await fulfillment(of: [conversionStarted], timeout: 5)
        withExtendedLifetime(controller) { }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
    #endif

    private func verifyManualConversion(existingSession: Bool) async throws {
        let id = "manual-detail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try EpubFixture.create()
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root.appendingPathComponent("imports"))
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                    AudioPlayer.currentChapterIndexDefaultsKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetBook = widgetDefaults?.object(forKey: "currentlyPlayingBookId")
        let audio = root.appendingPathComponent("existing-session.wav")
        if existingSession {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 120_000))
            buffer.frameLength = buffer.frameCapacity
            try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(buffer.frameLength))
            do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
            let snapshot = JobSnapshot(jobId: "unrelated-playing-book", state: "finished",
                bookTitle: "Other book", bookAuthor: nil, coverUrl: nil, coverMimeType: nil,
                engine: nil, voice: nil, language: nil, progressPercent: 35,
                chaptersTotal: 1, chaptersCompleted: 1,
                chapterProgress: [.init(index: 0, name: "Existing chapter", status: "completed",
                    downloadUrl: audio.absoluteString, chars: 100, charsProcessed: 100,
                    progressRatio: 1, durationSeconds: 15, startedAt: nil, completedAt: nil)],
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
            UserDefaults.standard.set(id, forKey: AudioPlayer.currentBookIDDefaultsKey)
            player.play(snapshot: snapshot, startingAt: 0, restoreAutoplay: false)
            player.resume()
            for _ in 0..<200 {
                if player.isPlaying && player.positionSeconds > 0 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(player.isPlaying)
            XCTAssertGreaterThan(player.positionSeconds, 0, "Use a progressing native AVPlayer, not just a snapshot")
            player.isConverting = true
        }
        let original = player.snapshot
        let playing = player.isPlaying
        let originalItem = player.testHook_currentPlayerItem()
        let converting = player.isConverting
        let expanded = presentation.showingFullPlayer
        var release: AsyncStream<Void>.Continuation!
        let completion = AsyncStream<Void> { release = $0 }
        defer {
            release.finish()
            player.stop()
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            widgetDefaults?.set(widgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        var requestedJob: String?
        let executor: RustConversionCoordinator.Executor = { url, job, start, end, progress, chapter in
            XCTAssertEqual(url.lastPathComponent, source.lastPathComponent)
            XCTAssertEqual(start, -1)
            XCTAssertEqual(end, -1, "Whole-book manual conversion remains explicit")
            requestedJob = job
            progress?(.init(jobId: job, state: "running", chapterIndex: 0, chaptersTotal: 1,
                chaptersCompleted: 0, percent: 50, engine: "edge", message: "converting chapter"))
            chapter?(.init(jobId: job, bookTitle: "Converted book", bookAuthor: "Author",
                chapterIndex: 0, chaptersTotal: 1, chaptersCompleted: 1, chapterTitle: "Manual chapter",
                filename: "manual.mp3", audioPath: root.appendingPathComponent("manual.mp3"), textChars: 10))
            for await _ in completion { }
            let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                "jobId": job, "title": "Converted book", "author": "Author", "chapters": []
            ]])
            return .init(jobID: job, manifestJSON: manifest, outputDirectory: root)
        }
        #if os(iOS)
        let controller = BookDetailScreenController(book: book, library: library,
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: presentation, conversionExecutor: executor)
        controller.loadViewIfNeeded()
        controller.downloadWholeBook()
        #else
        let controller = MacBookDetailViewController(book: book, library: library,
            settings: AppSettings(defaults: defaults), player: player,
            playerPresentation: presentation, onRead: { _ in }, onShowJobs: {},
            conversionExecutor: executor)
        _ = controller.view
        controller.convertWholeBook()
        #endif
        for _ in 0..<200 {
            if requestedJob != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let job = try XCTUnwrap(requestedJob)
        XCTAssertEqual(player.snapshot, original)
        XCTAssertEqual(player.isPlaying, playing, "Progress callbacks must not interrupt existing audio")
        XCTAssertTrue(player.testHook_currentPlayerItem() === originalItem)
        XCTAssertEqual(player.isConverting, converting)
        release.finish()
        for _ in 0..<200 {
            if library.books.first(where: { $0.id == book.id })?.lastJobId == job { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(library.books.first(where: { $0.id == book.id })?.lastJobId, job)
        try await library.flushPersistence()
        let reloaded = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root.appendingPathComponent("imports"))
        XCTAssertEqual(reloaded.books.first(where: { $0.id == book.id })?.lastJobId, job)
        XCTAssertEqual(player.snapshot, original, "Manual completion must not replace another listening session")
        XCTAssertEqual(player.isPlaying, playing)
        XCTAssertTrue(player.testHook_currentPlayerItem() === originalItem,
                      "Manual conversion must retain the same actual AVPlayerItem")
        XCTAssertEqual(player.isConverting, converting)
        XCTAssertEqual(presentation.showingFullPlayer, expanded)
        withExtendedLifetime(controller) { }
    }
}
#endif
