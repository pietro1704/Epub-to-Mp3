#if os(iOS) || os(macOS)
import XCTest
import AVFoundation
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

@MainActor
final class BookDetailManualConversionTests: XCTestCase {

    static let widgetPlaybackKeys = [
        "currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
        "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
        "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
        "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"
    ]
    #if os(iOS)




    func verifyBookDetailListenPlayback(forceEdgeFailure: Bool) async throws {
        let gate = forceEdgeFailure ? "EPUB2MP3_NATIVE_TTS_TEST" : "APP_IOS_LIVE_EDGE"
        guard ProcessInfo.processInfo.environment[gate] == "1" else {
            throw XCTSkip("Enable \(gate)=1 to exercise the actual Book Detail Listen action.")
        }

        let id = "detail-live-edge-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let body = String(repeating: "Este é um teste real de reprodução Edge no Simulator. ", count: 10)
        let source = try EpubFixture.createWithChapter(body: body, includeCover: false)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   importDirectory: root.appendingPathComponent("imports"))
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let firstChunkAccepted = expectation(description: "Edge audio chunk reaches the native player")
        let fallbackNoticeVisible = forceEdgeFailure
            ? expectation(description: "The actual app window promptly displays the fallback voice notice") : nil
        let noticeIsVisible: @MainActor @Sendable () -> Bool = {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return false }
            return self.descendants(window).compactMap { $0 as? UILabel }.contains {
                $0.text == L10n.string("conversion.systemVoiceFallback") && !$0.isHidden && $0.alpha > 0 && $0.window != nil
            }
        }
        let releaseConversion = DispatchSemaphore(value: 0)
        let conversionCompleted = expectation(description: "The remaining chapter audio finishes")
        let chunks = DetailNativeChunkCount()
        var usedSystemVoice = false
        let playbackKeys = [AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let savedPlayback = playbackKeys.map { UserDefaults.standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = Self.widgetPlaybackKeys
        let savedWidget = widgetKeys.map { widgetDefaults?.object(forKey: $0) }
        defer {
            releaseConversion.signal()
            player.stop()
            for (key, value) in zip(playbackKeys, savedPlayback) {
                restore(value, forKey: key, in: .standard)
            }
            for (key, value) in zip(widgetKeys, savedWidget) {
                restoreOptional(value, forKey: key, in: widgetDefaults)
            }
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        let controller = BookDetailScreenController(
            book: book, library: library, settings: AppSettings(defaults: defaults),
            player: player, playerPresentation: presentation,
            streamingExecutor: { url, jobID, chapterStart, chapterEnd, control, options, progress, chapter, audio in
                var selectedOptions = options ?? ConversionOptions(engine: "edge")
                if forceEdgeFailure {
                    selectedOptions.engine = "edge"
                    selectedOptions.voice = "pt-BR-UnavailableFixtureVoice"
                    selectedOptions.language = "pt-BR"
                }
                let result = try await RustConversionCoordinator.executeStreaming(
                    bookURL: url, jobID: jobID, chapterStart: chapterStart, chapterEnd: chapterEnd,
                    control: control, options: selectedOptions, onProgress: { event in
                        if event.engine == "system" && !usedSystemVoice {
                            usedSystemVoice = true
                            if let fallbackNoticeVisible {
                                if noticeIsVisible() {
                                    fallbackNoticeVisible.fulfill()
                                } else {
                                    Task { @MainActor in
                                        var visible = false
                                        for _ in 0..<20 {
                                            if noticeIsVisible() { visible = true; break }
                                            try? await Task.sleep(nanoseconds: 100_000_000)
                                        }
                                        XCTAssertTrue(visible, "The actual app window must promptly display the localized fallback notice.")
                                        fallbackNoticeVisible.fulfill()
                                    }
                                }
                            }
                        }
                        progress?(event)
                    },
                    onChapterCompleted: chapter,
                    onAudioChunk: { chapterIndex, chunkIndex, bytes in
                        chunks.increment()
                        let accepted = audio?(chapterIndex, chunkIndex, bytes) ?? false
                        if accepted && chunkIndex == 0 {
                            firstChunkAccepted.fulfill()
                            _ = releaseConversion.wait(timeout: .now() + 15)
                        }
                        return accepted
                    }
                )
                conversionCompleted.fulfill()
                return result
            },
            bookFileOpener: { _ in source }
        )
        controller.loadViewIfNeeded()
        let listen = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "bookDetail.listen" })
        let listenStartedAt = ProcessInfo.processInfo.systemUptime
        listen.sendActions(for: .touchUpInside)

        if let fallbackNoticeVisible {
            await fulfillment(of: [fallbackNoticeVisible], timeout: 20)
        }
        await fulfillment(of: [firstChunkAccepted], timeout: 30)
        if forceEdgeFailure {
            XCTAssertTrue(usedSystemVoice, "Listen must report the automatic Edge-to-system voice fallback.")
        } else {
            XCTAssertFalse(usedSystemVoice, "The live Edge golden path must not silently substitute a system voice.")
            XCTAssertFalse(player.isUsingSpeechFallback, "Listen must use generated Edge audio, not direct system speech.")
        }
        XCTAssertTrue(player.firstSegmentReady, "The first real MP3 chunk must be installed in AudioPlayer.")
        XCTAssertTrue(player.isPlaying, "Listen must start playback as soon as its first chunk is accepted.")
        XCTAssertNil(library.books.first(where: { $0.id == book.id })?.lastJobId,
                     "Playback must start before the held Rust conversion returns.")
        let queue = Mirror(reflecting: player).children
            .first { $0.label == "player" }?.value as? AVQueuePlayer
        for _ in 0..<30 where queue?.currentItem?.status == .unknown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(queue?.currentItem?.status, .readyToPlay)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertGreaterThan(queue?.currentTime().seconds ?? 0, 0.02,
                             "The native playback clock must advance before Rust conversion returns.")
        let firstPlaybackSeconds = ProcessInfo.processInfo.systemUptime - listenStartedAt
        let latency = XCTAttachment(string: "provider=\(forceEdgeFailure ? "system-fixture" : "edge") firstPlaybackSeconds=\(firstPlaybackSeconds) freshAudio=true conversionHeld=true")
        latency.name = "Actual first playback latency"
        latency.lifetime = .keepAlways
        add(latency)
        if !forceEdgeFailure {
            XCTAssertLessThan(firstPlaybackSeconds, 10,
                              "Fresh Edge playback should start within ten seconds on the physical-device golden path.")
        }
        XCTAssertNil(library.books.first(where: { $0.id == book.id })?.lastJobId)
        XCTAssertEqual(chunks.get(), 1, "Listen must start while the chapter still awaits additional audio chunks.")
        releaseConversion.signal()
        await fulfillment(of: [conversionCompleted], timeout: 45)
        if !forceEdgeFailure {
            XCTAssertFalse(usedSystemVoice, "Every segment of the live Edge golden path must remain on Edge.")
            XCTAssertFalse(player.isUsingSpeechFallback)
        }
        XCTAssertGreaterThanOrEqual(chunks.get(), 2, "The first playable segment must cover only part of the chapter.")
        withExtendedLifetime(controller) { }
    }

    #endif



    #if os(macOS)
    #endif

    #if os(iOS)

    func verifyBookDetailOpenIsAsynchronous(actionIdentifier: String) async throws {
        let id = "detail-open-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try EpubFixture.createWithChapter(body: "Book Detail actions open this readable chapter asynchronously.")
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
        let executor: RustConversionCoordinator.Executor = { url, job, _, _, _, _, _ in
            XCTAssertEqual(url.lastPathComponent, source.lastPathComponent)
            conversionStarted.fulfill()
            let manifest = try JSONSerialization.data(withJSONObject: ["manifest": [
                "jobId": job, "title": "Opened book", "chapters": []
            ]])
            return .init(jobID: job, manifestJSON: manifest, outputDirectory: root)
        }
        let streamingExecutor: RustConversionCoordinator.StreamingExecutor = { url, job, _, _, _, _, _, _, _ in
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
            streamingExecutor: streamingExecutor,
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

    func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func restoreOptional(_ value: Any?, forKey key: String, in defaults: UserDefaults?) {
        guard let defaults else { return }
        restore(value, forKey: key, in: defaults)
    }
    #endif

    func verifyManualConversion(existingSession: Bool) async throws {
        let id = "manual-detail-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
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
        let executor: RustConversionCoordinator.Executor = { url, job, start, end, options, progress, chapter in
            XCTAssertEqual(url.lastPathComponent, source.lastPathComponent)
            XCTAssertEqual(start, -1)
            XCTAssertEqual(end, -1, "Whole-book manual conversion remains explicit")
            XCTAssertEqual(options?.engine, "edge")
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
        controller.convertWholeBook(options: AppSettings(defaults: defaults).conversionOptions)
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

    #if os(macOS)
    func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func restoreMac(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    func restoreOptionalMac(_ value: Any?, forKey key: String, in defaults: UserDefaults?) {
        guard let defaults else { return }
        restoreMac(value, forKey: key, in: defaults)
    }
    #endif
}
final class DetailNativeChunkCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
