#if os(iOS) || os(macOS)
import XCTest
import AVFoundation
@testable import EpubToMp3

@MainActor
final class BookDetailManualConversionTests: XCTestCase {
    private static let widgetPlaybackKeys = [
        "currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
        "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
        "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
        "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"
    ]
    #if os(iOS)
    func testListenUsesStreamingExecutorInsteadOfWholeBookConversion() async throws {
        let id = "detail-listen-streaming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
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

        let controller = BookDetailScreenController(
            book: book, library: library, settings: AppSettings(defaults: defaults),
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
                XCTAssertNotNil(chunk, "Listen must supply the incremental audio callback.")
                pendingPlaybackInstalled = player.snapshot?.jobId == jobID && player.isConverting
                started.fulfill()
                return try result(jobID: jobID)
            },
            bookFileOpener: { _ in source }
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

    func testListenIgnoresRepeatedTapWhileBookURLIsOpening() async throws {
        let id = "detail-listen-single-flight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
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

    func testOptInLiveEdgeListenStartsNativePlaybackBeforeConversionReturns() async throws {
        try await verifyBookDetailListenPlayback(forceEdgeFailure: false)
    }

    func testOptInEdgeFailureListenUsesSystemVoiceBeforeConversionReturns() async throws {
        try await verifyBookDetailListenPlayback(forceEdgeFailure: true)
    }

    private func verifyBookDetailListenPlayback(forceEdgeFailure: Bool) async throws {
        let gate = forceEdgeFailure ? "EPUB2MP3_NATIVE_TTS_TEST" : "APP_IOS_LIVE_EDGE"
        guard ProcessInfo.processInfo.environment[gate] == "1" else {
            throw XCTSkip("Enable \(gate)=1 to exercise the actual Book Detail Listen action.")
        }

        let id = "detail-live-edge-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
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

    func testOptInLiveEdgeManualConvertCreatesAudioWithoutAutoplay() async throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Set APP_IOS_LIVE_EDGE=1 to exercise live Edge manual conversion on iOS.")
        }

        let id = "detail-live-edge-manual-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try EpubFixture.createWithChapter(
            body: "Esta conversão Edge integral deve gerar um MP3 sem iniciar reprodução automática.",
            includeCover: false
        )
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   importDirectory: root.appendingPathComponent("imports"))
        let book = try library.importBook(from: source)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        let conversionCompleted = expectation(description: "Manual whole-book Edge conversion completes")
        var conversionResult: RustConversionCoordinator.Result?
        var conversionStart: Int32?
        var conversionEnd: Int32?
        var selectedEngine: String?
        let playbackKeys = [AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey]
        let savedPlayback = playbackKeys.map { UserDefaults.standard.object(forKey: $0) }
        let widgetDefaults = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = Self.widgetPlaybackKeys
        let savedWidget = widgetKeys.map { widgetDefaults?.object(forKey: $0) }
        defer {
            player.stop()
            for (key, value) in zip(playbackKeys, savedPlayback) {
                restore(value, forKey: key, in: .standard)
            }
            for (key, value) in zip(widgetKeys, savedWidget) {
                restoreOptional(value, forKey: key, in: widgetDefaults)
            }
            if let output = conversionResult?.outputDirectory {
                try? FileManager.default.removeItem(at: output)
            }
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }

        let controller = BookDetailScreenController(
            book: book, library: library, settings: AppSettings(defaults: defaults),
            player: player, playerPresentation: presentation,
            conversionExecutor: { url, jobID, chapterStart, chapterEnd, options, progress, chapter in
                conversionStart = chapterStart
                conversionEnd = chapterEnd
                selectedEngine = options?.engine
                let result = try await RustConversionCoordinator.execute(
                    bookURL: url, jobID: jobID, chapterStart: chapterStart, chapterEnd: chapterEnd,
                    options: options, onProgress: progress, onChapterCompleted: chapter
                )
                conversionResult = result
                conversionCompleted.fulfill()
                return result
            },
            bookFileOpener: { _ in source }
        )
        controller.loadViewIfNeeded()
        let convert = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "bookDetail.download" })
        convert.sendActions(for: .touchUpInside)

        await fulfillment(of: [conversionCompleted], timeout: 45)
        let result = try XCTUnwrap(conversionResult)
        XCTAssertEqual(conversionStart, -1)
        XCTAssertEqual(conversionEnd, -1, "Manual Convert must process the entire book.")
        XCTAssertEqual(selectedEngine, "edge")
        XCTAssertNil(player.snapshot, "Manual Convert must not create a playback session.")
        XCTAssertFalse(player.isPlaying, "Manual Convert must not autoplay its generated audio.")
        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.chaptersTotal, 1)
        let chapter = try XCTUnwrap(snapshot.chapterProgress?.first)
        let audioURL = URL(fileURLWithPath: try XCTUnwrap(chapter.downloadUrl))
        XCTAssertTrue(audioURL.lastPathComponent.hasSuffix(".mp3"))
        XCTAssertGreaterThan(try Data(contentsOf: audioURL).count, 0)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: result.manifestJSON) as? [String: Any])
        XCTAssertNotEqual(envelope["systemVoiceUsed"] as? Bool, true,
                          "The live Edge download golden path must not silently substitute platform speech.")
        let manifest = try XCTUnwrap(envelope["manifest"] as? [String: Any])
        let archiveName = try XCTUnwrap(manifest["archive"] as? String)
        let archiveURL = result.outputDirectory.appendingPathComponent(archiveName)
        XCTAssertGreaterThan(try Data(contentsOf: archiveURL).count, 0)
        XCTAssertEqual(library.books.first(where: { $0.id == book.id })?.lastJobId, result.jobID)
        defer { DownloadManager.deleteAudiobook(jobId: result.jobID) }
        let downloads = DownloadManager()
        let updates = await downloads.watchProgress(jobId: result.jobID)
        let downloadFinished = expectation(description: "Fresh Edge audio is persisted for offline playback")
        let observation = Task {
            for await update in updates {
                if update.state == .completed || update.state == .failed {
                    XCTAssertEqual(update.state, .completed)
                    downloadFinished.fulfill()
                    break
                }
            }
        }
        defer { observation.cancel() }
        await downloads.enqueueAll(snapshot: snapshot, baseURL: nil)
        await fulfillment(of: [downloadFinished], timeout: 15)
        let localSnapshot = try XCTUnwrap(DownloadManager.localPlaybackSnapshot(jobId: result.jobID))
        let localURL = try XCTUnwrap(DownloadManager.localAudioURL(jobId: result.jobID, chapterIndex: chapter.index))
        let localDuration = try await AVURLAsset(url: localURL).load(.duration)
        XCTAssertGreaterThan(localDuration.seconds, 0)
        player.play(snapshot: localSnapshot, startingAt: 0)
        player.resume()
        let offlineQueue = Mirror(reflecting: player).children
            .first { $0.label == "player" }?.value as? AVQueuePlayer
        let retainedAsset = try XCTUnwrap(offlineQueue?.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(retainedAsset.url, localURL,
                       "Playback must use the protected downloaded file, not its temporary conversion source.")
        for _ in 0..<50 where (offlineQueue?.currentTime().seconds ?? 0) < 0.02 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(offlineQueue?.currentTime().seconds ?? 0, 0.02,
                             "The downloaded Edge MP3 must play from its persisted local file.")
        XCTAssertFalse(player.isUsingSpeechFallback)
        withExtendedLifetime(controller) { }
    }
    #endif

    func testManualCompletionPreservesExistingPlaybackSession() async throws {
        try await verifyManualConversion(existingSession: true)
    }

    func testManualCompletionDoesNotCreatePlaybackSession() async throws {
        try await verifyManualConversion(existingSession: false)
    }

    #if os(macOS)
    func testMacListenRoutesThroughStreamingExecutor() async throws {
        let id = "detail-streaming-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
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

    private func verifyBookDetailOpenIsAsynchronous(actionIdentifier: String) async throws {
        let id = "detail-open-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
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

    private func restoreOptional(_ value: Any?, forKey key: String, in defaults: UserDefaults?) {
        guard let defaults else { return }
        restore(value, forKey: key, in: defaults)
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

    #if os(macOS)
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func restoreMac(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }

    private func restoreOptionalMac(_ value: Any?, forKey key: String, in defaults: UserDefaults?) {
        guard let defaults else { return }
        restoreMac(value, forKey: key, in: defaults)
    }
    #endif
}
private final class DetailNativeChunkCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
#endif
