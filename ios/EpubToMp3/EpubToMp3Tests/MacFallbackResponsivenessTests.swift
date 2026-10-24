#if os(macOS)
import AppKit
import AVFoundation
import XCTest
@testable import EpubToMp3

@MainActor
final class MacFallbackResponsivenessTests: XCTestCase {
    func testClosingExpandedPlayerAfterFallbackReleasesReaderWindow() async throws {
        let suite = "MacFallbackPresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        player.setSnapshot(try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"fallback-presentation","state":"running","engine":"system"}"#.utf8)))
        let presentation = PlayerPresentation(defaults: defaults)
        let root = MacAppKitRootController(settings: AppSettings(defaults: defaults),
            library: LibraryStore(defaults: defaults, defaultsKey: "library"), player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: presentation)
        let window = NSWindow(contentViewController: root)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.makeKeyAndOrderFront(nil)
        defer {
            for controller in root.presentedViewControllers ?? [] { root.dismiss(controller) }
            player.stop()
            window.orderOut(nil)
            window.contentViewController = nil
            defaults.removePersistentDomain(forName: suite)
        }
        PlatformFallbackNotice.show(engine: "system")
        // A chapter callback and final manifest may both request expansion.
        presentation.showFullPlayer()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(root.presentedViewControllers?.count, 1, "One expansion must present the committed state.")
        presentation.showFullPlayer()
        try await Task.sleep(nanoseconds: 100_000_000)
        let expanded = try XCTUnwrap(root.presentedViewControllers?.first)
        XCTAssertEqual(root.presentedViewControllers?.count, 1)
        XCTAssertNotNil(window.attachedSheet)
        func closeButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.action == NSSelectorFromString("closePlayer") { return button }
            return view.subviews.lazy.compactMap { closeButton(in: $0) }.first
        }
        let close = try XCTUnwrap(closeButton(in: expanded.view))
        let closed = expectation(forNotification: NSWindow.didEndSheetNotification, object: window)
        close.performClick(nil)
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertFalse(presentation.showingFullPlayer)
        XCTAssertTrue(root.presentedViewControllers?.isEmpty ?? true)
        XCTAssertNil(window.attachedSheet, "A stuck sheet blocks the reader and bottom-bar interaction while audio can continue.")
        presentation.showFullPlayer()
        presentation.dismissFullPlayer()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(window.attachedSheet, "A retired expansion must not reopen a sheet after a newer dismissal.")
    }

    func testOptInLocalFallbackKeepsTransportResponsiveAndRetiresConversion() async throws {
        let source = try EpubFixture.createWithChapter(
            body: String(repeating: "The local voice reads this fixture while the transport remains responsive. ", count: 25),
            includeCover: false, language: "en"
        )
        defer { try? FileManager.default.removeItem(at: source) }
        try await verifyFallback(source: source, readerChapter: 0, pageRatio: 0)
    }

    func testOptInImportedReaderFallbackRemainsResponsive() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUB2MP3_LOTR_IMPORTED_EPUB"],
              !path.isEmpty, !path.contains("$("), !path.contains("${") else {
            throw XCTSkip("Explicitly provide EPUB2MP3_LOTR_IMPORTED_EPUB; never discover or download a private book.")
        }
        executionTimeAllowance = 60
        try await verifyFallback(source: URL(fileURLWithPath: path), readerChapter: 23, pageRatio: 0.4)
    }

    func testOptInImportedReaderNavigationStartsANewRealRustSourceJob() async throws {
        guard let path = ProcessInfo.processInfo.environment["EPUB2MP3_LOTR_IMPORTED_EPUB"],
              !path.isEmpty, !path.contains("$("), !path.contains("${") else {
            throw XCTSkip("Explicitly provide EPUB2MP3_LOTR_IMPORTED_EPUB; never discover or download a private book.")
        }
        executionTimeAllowance = 60
        try await verifyFallback(source: URL(fileURLWithPath: path), readerChapter: 23,
            pageRatio: 0.2, nextReaderChapter: 24)
    }

    private func verifyFallback(source: URL, readerChapter: Int, pageRatio: Double,
                                nextReaderChapter: Int? = nil) async throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_NATIVE_TTS_TEST"] == "1" else {
            throw XCTSkip("Enable EPUB2MP3_NATIVE_TTS_TEST=1 for installed local speech and audible playback.")
        }
        let suite = "MacFallbackResponsiveness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let missingModels = directory.appendingPathComponent("missing-models")
        try FileManager.default.createDirectory(at: missingModels, withIntermediateDirectories: true)
        let library = LibraryStore(defaults: defaults, defaultsKey: "library",
            importDirectory: directory.appendingPathComponent("books"))
        let book = try library.importBook(from: source)
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
            AudioPlayer.readerCurrentSentenceIdDefaultsKey,
            "readerProgress.v1", "readerWarmBookIDs.v1"]
        let saved = keys.map { standard.object(forKey: $0) }
        let retired = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"fixture-retired","state":"cancelled"}"#.utf8))
        standard.set(book.id, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(book.id, forKey: AudioPlayer.currentBookIDDefaultsKey)
        standard.set(readerChapter, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        standard.set(pageRatio, forKey: AudioPlayer.readerCurrentPageRatioDefaultsKey)
        ReaderProgressStore.save(bookId: book.id, chapterIndex: readerChapter, offsetFraction: pageRatio)

        let settings = AppSettings(defaults: defaults)
        settings.audioEngine = .piper
        settings.selectSecondaryNarration(.selected(.system))
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let presentation = PlayerPresentation(defaults: defaults)
        var control: ConverterPlaybackControl?
        var observedFallback = false
        var requests: [(jobID: String, chapter: Int32)] = []
        let finished = expectation(description: "Retired fallback conversion returns")
        finished.expectedFulfillmentCount = nextReaderChapter == nil ? 1 : 2
        let root = MacAppKitRootController(settings: settings, library: library, player: player,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks"),
            playerPresentation: presentation,
            conversionExecutor: { url, jobID, start, end, currentControl, options, progress, chapter, chunks in
                requests.append((jobID, start))
                control = currentControl
                var scopedOptions = options ?? ConversionOptions()
                scopedOptions.modelsRoot = missingModels.path
                defer { finished.fulfill() }
                return try await RustConversionCoordinator.executeStreaming(bookURL: url, jobID: jobID,
                    chapterStart: start, chapterEnd: start, control: currentControl, options: scopedOptions,
                    onProgress: { event in
                        if event.engine == "system" { observedFallback = true }
                        progress?(event)
                    }, onChapterCompleted: chapter, onAudioChunk: chunks)
            })
        let window = NSWindow(contentViewController: root)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        root.showReader(bookID: book.id)
        defer {
            // Retire the session before a cancellation error can present a modal.
            player.setSnapshot(retired)
            player.stop()
            control?.cancel()
            window.orderOut(nil)
            window.contentViewController = nil
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            defaults.removePersistentDomain(forName: suite)
        }
        root.startPlaybackForCurrentBook()
        // Progress and chunk callbacks hop to MainActor independently.
        // Wait for both observations instead of assuming their arrival order.
        for _ in 0..<200 where !player.firstSegmentReady || !observedFallback {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(observedFallback, "Missing primary must select the captured installed-system secondary.")
        XCTAssertTrue(player.firstSegmentReady)
        let item = try XCTUnwrap(player.testHook_currentPlayerItem(), "The initial selected chapter must remain playable")
        for _ in 0..<50 where item.status == .unknown {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertGreaterThan(item.currentTime().seconds, 0.02)
        print("Native fallback active voice: \(player.snapshot?.voice ?? "unresolved")")

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        if let expanded = root.presentedViewControllers?.first {
            let close = try XCTUnwrap(descendants(expanded.view).compactMap { $0 as? NSButton }
                .first { $0.action == NSSelectorFromString("closePlayer") })
            close.performClick(nil)
            for _ in 0..<30 where window.attachedSheet != nil { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertNil(window.attachedSheet)
        }

        func playButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.action == NSSelectorFromString("togglePlayback") { return button }
            return view.subviews.lazy.compactMap { playButton(in: $0) }.first
        }
        let pause = try XCTUnwrap(playButton(in: root.view))
        XCTAssertTrue(pause.isEnabled)
        try retainWindow(window, name: "local-fallback-before-bottom-bar-pause")
        pause.performClick(nil)
        XCTAssertFalse(player.isPlaying, "The actual bottom-bar Pause must still respond after fallback.")
        if let nextReaderChapter {
            let fulltext = try XCTUnwrap(LocalFulltextCache.read(bookId: book.id))
            let rows = ReaderTocFlattener.rows(toc: fulltext.toc, chapters: fulltext.chapters)
            let row = try XCTUnwrap(rows.firstIndex { row in
                guard let ordinal = row.chapterIndex, fulltext.chapters.indices.contains(ordinal) else { return false }
                return fulltext.chapters[ordinal].zeroBasedEpubIndex == nextReaderChapter
            })
            let contents = try XCTUnwrap(descendants(root.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "reader.toc.toggle" })
            contents.performClick(nil)
            let table = try XCTUnwrap(NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }
                .compactMap { $0 as? NSTableView }.first { $0.numberOfRows == rows.count })
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            for _ in 0..<100 where standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey) != nextReaderChapter {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), nextReaderChapter)
            let firstJob = try XCTUnwrap(requests.first?.jobID)
            pause.performClick(nil)
            for _ in 0..<200 {
                if requests.count == 2, player.firstSegmentReady, player.snapshot?.jobId == requests.last?.jobID { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.last?.chapter, Int32(nextReaderChapter))
            XCTAssertNotEqual(requests.last?.jobID, firstJob)
            XCTAssertEqual(player.snapshot?.jobId, requests.last?.jobID)
            XCTAssertNil(window.attachedSheet)
            let replacement = try XCTUnwrap(player.testHook_currentPlayerItem(), "The replacement selected chapter must be playable")
            for _ in 0..<30 where replacement.status == .unknown { try await Task.sleep(nanoseconds: 100_000_000) }
            try await Task.sleep(nanoseconds: 400_000_000)
            XCTAssertTrue(player.isPlaying)
            XCTAssertGreaterThan(replacement.currentTime().seconds, 0.02)
            try retainWindow(window, name: "local-fallback-after-source-navigation")
            pause.performClick(nil)
            XCTAssertFalse(player.isPlaying)
        }
        let responsive = expectation(description: "The main event queue continues after fallback")
        DispatchQueue.main.async { responsive.fulfill() }
        await fulfillment(of: [responsive], timeout: 3)
        player.setSnapshot(try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"fixture-replacement","state":"running"}"#.utf8)))
        XCTAssertEqual(player.snapshot?.jobId, "fixture-replacement")
        player.stop()
        XCTAssertTrue(try XCTUnwrap(control).isCancellationRequested)
        await fulfillment(of: [finished], timeout: 10)
        XCTAssertNil(player.snapshot, "Retired callbacks must not resurrect playback after Stop.")
        // Retain the isolated conversion log/artifacts for diagnosing a failed run.
    }

    private func retainWindow(_ window: NSWindow, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
#endif
