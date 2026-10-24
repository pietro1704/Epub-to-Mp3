#if os(macOS)
import AppKit
import AVFoundation
import XCTest
@testable import EpubToMp3

@MainActor
final class MacReaderListeningRestartTests: XCTestCase {
    func testOptInStartCapturesTextPositionBeforeAsyncBookAccess() async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 for installed local speech through the real Rust runtime.")
        }
        let suite = "MacReaderCapturedText.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
        let source = try EpubFixture.createWithChapters((0..<12).map { "First known words in source chapter \($0 + 1)." })
        let book = try library.importBook(from: source)
        let missingModels = directory.appendingPathComponent("missing-models")
        try FileManager.default.createDirectory(at: missingModels, withIntermediateDirectories: true)
        let settings = AppSettings(defaults: defaults)
        settings.selectSecondaryNarration(.selected(.system))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(
            with: ConverterFFIAdapter().openBook(at: source).metadataJSON) as? [String: Any])
        let chapters = try XCTUnwrap(metadata["chapters"] as? [[String: Any]])
        let count = try XCTUnwrap(chapters[10]["textChars"] as? Int)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var offset: Int?
        let completed = expectation(description: "The captured source remainder is persisted")
        var session: MacReaderPlaybackSession!
        session = MacReaderPlaybackSession(settings: settings, library: library,
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { url, jobID, start, _, control, options, _, _, _ in
                defer { session.cancel() }
                var scoped = options ?? ConversionOptions()
                scoped.language = "en"
                scoped.modelsRoot = missingModels.path
                let result = try await RustConversionCoordinator.executeStreaming(bookURL: url,
                    jobID: jobID, chapterStart: start, chapterEnd: start, control: control, options: scoped,
                    onProgress: nil, onChapterCompleted: nil, onAudioChunk: nil)
                offset = try result.snapshot().chapterProgress?.first?.textOffset
                completed.fulfill()
                return result
            })
        defer {
            session.cancel()
            session = nil
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            for url in [source, directory] { try? FileManager.default.removeItem(at: url) }
        }
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(10, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.2, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        session.start(owner: self)
        standard.set(11, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.9, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        await fulfillment(of: [completed], timeout: 20)
        XCTAssertEqual(offset, Int((Double(count) * 0.2).rounded(.down)))
        XCTAssertNotEqual(offset, Int((Double(count) * 0.9).rounded(.down)))
    }

    func testStartCapturesChapterBeforeAsyncBookAccess() async throws {
        let suite = "MacReaderCapturedStart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory)
        let source = try EpubFixture.createWithChapters((0..<12).map { "Source chapter \($0 + 1)." })
        let book = try library.importBook(from: source)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        var submittedChapter: Int32?
        let submitted = expectation(description: "Captured reader request arrives")
        var session: MacReaderPlaybackSession!
        session = MacReaderPlaybackSession(settings: AppSettings(defaults: defaults), library: library,
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, _, start, _, _, _, _, _, _ in
                submittedChapter = start
                submitted.fulfill()
                session.cancel()
                throw CancellationError()
            })
        defer {
            session.cancel()
            player.stop()
            session = nil
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            for url in [source, directory] { try? FileManager.default.removeItem(at: url) }
        }
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(10, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.2, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        session.start(owner: self)
        // This navigation happens before the MainActor task can open the file.
        standard.set(11, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.9, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        await fulfillment(of: [submitted], timeout: 5)
        XCTAssertEqual(submittedChapter, 10, "An accepted Play intent must retain its selected source chapter.")
    }

    func testBottomBarPlayAfterChapterElevenSelectionStartsANewSourceJob() async throws {
        let suite = "MacReaderChapterPlay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = try EpubFixture.createWithChapters((0..<12).map { index in
            String(repeating: "Source chapter \(index + 1) opening words. ", count: 40)
        })
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: directory.appendingPathComponent("books"))
        let book = try library.importBook(from: source)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.readerCurrentSentenceIdDefaultsKey, AudioPlayer.currentBookIDDefaultsKey,
            AudioPlayer.currentChapterIndexDefaultsKey, "readerProgress.v1", "readerWarmBookIDs.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.0, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        ReaderProgressStore.save(bookId: book.id, chapterIndex: 0, offsetFraction: 0)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let audio = directory.appendingPathComponent("old-chapter.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        samples.frameLength = samples.frameCapacity
        try XCTUnwrap(samples.floatChannelData?[0]).initialize(repeating: 0, count: Int(samples.frameLength))
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: samples) }
        let oldChapter = JobSnapshot.Chapter(index: 0, name: "Source chapter 1", status: "completed",
            downloadUrl: audio.path, chars: 1300, charsProcessed: 1300, progressRatio: 1,
            durationSeconds: 60, startedAt: nil, completedAt: nil)
        let followingAudio = directory.appendingPathComponent("following-chapter.wav")
        try FileManager.default.copyItem(at: audio, to: followingAudio)
        let followingChapter = JobSnapshot.Chapter(index: 1, name: "Source chapter 2", status: "completed",
            downloadUrl: followingAudio.path, chars: 1300, charsProcessed: 1300, progressRatio: 1,
            durationSeconds: 60, startedAt: nil, completedAt: nil)
        let oldSnapshot = JobSnapshot(jobId: suite, state: "finished", bookTitle: "Chapter navigation",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "fixture", voice: nil, language: nil,
            progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2, chapterProgress: [oldChapter, followingChapter],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        library.recordConversion(jobId: suite, for: book.id)
        player.play(snapshot: oldSnapshot, restoreAutoplay: false)
        var submissions: [(jobID: String, chapter: Int32)] = []
        var pending: [CheckedContinuation<RustConversionCoordinator.Result, Error>] = []
        let root = MacAppKitRootController(settings: AppSettings(defaults: defaults), library: library,
            player: player, bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, jobID, start, _, _, _, _, _, _ in
                submissions.append((jobID, start))
                return try await withCheckedThrowingContinuation { pending.append($0) }
            })
        let window = NSWindow(contentViewController: root)
        window.setContentSize(NSSize(width: 1000, height: 750))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let retired = try JSONDecoder().decode(JobSnapshot.self, from: Data(#"{"jobId":"retired-fixture","state":"cancelled"}"#.utf8))
        defer {
            for presented in root.presentedViewControllers ?? [] { root.dismiss(presented) }
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            player.setSnapshot(retired)
            player.stop()
            pending.forEach { $0.resume(throwing: CancellationError()) }
            window.orderOut(nil)
            window.contentViewController = nil
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            for url in [source, directory] { try? FileManager.default.removeItem(at: url) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        root.showReader(bookID: book.id)
        for _ in 0..<100 where !descendants(root.view).contains(where: {
            ($0 as? NSTextView)?.string.contains("Source chapter 1 opening words.") == true
        }) { try await Task.sleep(nanoseconds: 50_000_000) }
        let item = try XCTUnwrap(player.testHook_currentPlayerItem())
        for _ in 0..<30 where item.status == .unknown { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(item.status, .readyToPlay)
        player.resume()
        player.pause()
        let play = try XCTUnwrap(descendants(root.view).compactMap { $0 as? NSButton }
            .first { $0.action == NSSelectorFromString("togglePlayback") })
        play.performClick(nil)
        XCTAssertTrue(player.isPlaying, "Unchanged reader location must resume the existing audio.")
        XCTAssertTrue(submissions.isEmpty)
        // Advancing the real audio queue does not move the reader's anchor.
        player.nextChapter()
        for _ in 0..<30 where player.currentChapterIndex != 1 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(player.currentChapterIndex, 1)
        play.performClick(nil)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 0)
        play.performClick(nil)
        for _ in 0..<10 where !player.isPlaying { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(submissions.isEmpty, "Audio advancement must not be mistaken for a new reader chapter selection.")
        XCTAssertEqual(player.snapshot?.jobId, suite)
        guard submissions.isEmpty else { return }
        XCTAssertTrue(player.isPlaying)
        play.performClick(nil)
        XCTAssertFalse(player.isPlaying)
        let contents = try XCTUnwrap(descendants(root.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == "reader.toc.toggle" })
        contents.performClick(nil)
        let table = try XCTUnwrap(NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }
            .compactMap { $0 as? NSTableView }.first { $0.numberOfRows == 12 })
        table.selectRowIndexes(IndexSet(integer: 10), byExtendingSelection: false)
        for _ in 0..<100 where standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey) != 10 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 10)
        play.performClick(nil)
        for _ in 0..<30 where submissions.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertNil(window.attachedSheet, "A newly selected chapter is an explicit source request, not an old-position resume choice.")
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.chapter, 10)
        XCTAssertNotEqual(submissions.first?.jobID, suite)
        XCTAssertEqual(player.snapshot?.jobId, submissions.first?.jobID)
    }

    func testNewPageRetiresJobControlAndLateProgressAndAudio() async throws {
        let suite = "mac-listening-restart-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: root)
        let input = try EpubFixture.createWithChapter(body: "First selected words. Second selected words.", includeCover: false)
        let book = try library.importBook(from: input)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let first = expectation(description: "First page job submitted")
        let second = expectation(description: "Second page job submitted")
        var jobs: [String] = []
        var controls: [ConverterPlaybackControl] = []
        var progress: [(@MainActor @Sendable (RustConversionCoordinator.ConversionProgressEvent) -> Void)?] = []
        var chunks: [(@Sendable (Int, Int, Data) -> Bool)?] = []
        var pending: [CheckedContinuation<RustConversionCoordinator.Result, Error>] = []
        let session = MacReaderPlaybackSession(settings: AppSettings(defaults: defaults), library: library,
            player: player, playerPresentation: PlayerPresentation(defaults: defaults),
            conversionExecutor: { _, jobID, _, _, control, _, onProgress, _, onChunk in
                jobs.append(jobID)
                controls.append(control)
                progress.append(onProgress)
                chunks.append(onChunk)
                return try await withCheckedThrowingContinuation { continuation in
                    pending.append(continuation)
                    if jobs.count == 1 { first.fulfill() } else { second.fulfill() }
                }
            })
        defer {
            session.cancel()
            for continuation in pending { continuation.resume(throwing: CancellationError()) }
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
            for url in [root, input] { try? FileManager.default.removeItem(at: url) }
        }
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(0.2, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        session.start(owner: self)
        await fulfillment(of: [first], timeout: 5)
        standard.set(0.7, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        session.start(owner: self)
        await fulfillment(of: [second], timeout: 5)
        XCTAssertEqual(jobs.count, 2)
        XCTAssertNotEqual(jobs[0], jobs[1])
        XCTAssertTrue(controls[0].isCancellationRequested)
        XCTAssertFalse(controls[1].isCancellationRequested)
        progress[0]?(.init(jobId: jobs[0], state: "running", chapterIndex: 0,
            chaptersTotal: 1, chaptersCompleted: 0, percent: 90, engine: "retired", message: "Retired progress"))
        XCTAssertEqual(player.snapshot?.jobId, jobs[1])
        XCTAssertNotEqual(player.snapshot?.engine, "retired")
        let retiredChunk = chunks[0]
        let accepted = await Task.detached { retiredChunk?(0, 0, Data([1, 2])) }.value
        XCTAssertEqual(accepted, false)
    }
}
#endif
