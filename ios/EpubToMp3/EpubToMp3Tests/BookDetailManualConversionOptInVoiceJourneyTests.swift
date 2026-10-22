#if os(iOS) || os(macOS)
import XCTest
import AVFoundation
#if os(macOS)
import AppKit
#endif

@testable import EpubToMp3

extension BookDetailManualConversionTests {
#if os(iOS)
    func testOptInLiveEdgeListenStartsNativePlaybackBeforeConversionReturns() async throws {
        try await verifyBookDetailListenPlayback(forceEdgeFailure: false)
    }
#endif

#if os(iOS)
    func testOptInEdgeFailureListenUsesSystemVoiceBeforeConversionReturns() async throws {
        try await verifyBookDetailListenPlayback(forceEdgeFailure: true)
    }
#endif

#if os(iOS)
    func testOptInLiveEdgeManualConvertCreatesAudioWithoutAutoplay() async throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_LIVE_EDGE"] == "1" else {
            throw XCTSkip("Set APP_IOS_LIVE_EDGE=1 to exercise live Edge manual conversion on iOS.")
        }

        let id = "detail-live-edge-manual-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        defaults.set("edge", forKey: AppSettings.audioEngineKey)
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
        defer { AudiobookDownloadStorage.deleteAudiobook(jobId: result.jobID) }
        let downloads = AudiobookDownloads()
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
        let localSnapshot = try XCTUnwrap(AudiobookDownloadStorage.localPlaybackSnapshot(jobId: result.jobID))
        let localURL = try XCTUnwrap(AudiobookDownloadStorage.localAudioURL(jobId: result.jobID, chapterIndex: chapter.index))
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
}
#endif
