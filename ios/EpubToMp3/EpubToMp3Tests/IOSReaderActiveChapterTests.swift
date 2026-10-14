#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

private final class ReaderOpenStageNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func append(_ name: String) {
        lock.lock()
        names.append(name)
        lock.unlock()
    }

    func count(_ name: String) -> Int {
        lock.lock()
        let result = names.filter { $0 == name }.count
        lock.unlock()
        return result
    }

    func snapshot() -> [String] {
        lock.lock()
        let result = names
        lock.unlock()
        return result
    }
}

@MainActor
final class IOSReaderActiveChapterTests: XCTestCase {
    func testPreparedChapterIsVisibleWhileCatalogHydrationIsSuspended() async throws {
        try await verifyProjectionHydration(mismatchedCatalog: false)
    }

    func testMismatchedCatalogFallsBackToHydratedChapter() async throws {
        try await verifyProjectionHydration(mismatchedCatalog: true)
    }

    func testLaunchRestorationMakesControlsUsableWithReadableChapter() async throws {
        try await verifyProjectionHydration(mismatchedCatalog: false, launchRestore: true)
    }

    func testShortPreparedScrollingChapterCompletesLaunchRestoration() async throws {
        try await verifyProjectionHydration(mismatchedCatalog: false, launchRestore: true,
                                            shortChapter: true, layout: .scrolling)
    }

    func testShortPreparedPaginatedChapterCompletesLaunchRestoration() async throws {
        try await verifyProjectionHydration(mismatchedCatalog: false, launchRestore: true,
                                            shortChapter: true, layout: .paginated)
    }

    private func verifyProjectionHydration(mismatchedCatalog: Bool, launchRestore: Bool = false,
                                          shortChapter: Bool = false, layout: ReaderLayout = .scrolling) async throws {
        let id = "ios-active-chapter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let book = BookEntity(id: id, title: "Active chapter", bookmark: Data([1]),
                              displayFilename: "active.epub", addedAt: Date())
        let repetitions = shortChapter ? 1 : 100
        let payload = EbookFulltext(jobId: id, bookTitle: "Active chapter", bookAuthor: "Author", chapters: [
            .init(index: 3, name: "Previous", text: String(repeating: "Previous chapter.\n", count: 80),
                  html: nil, css: nil, charCount: nil, segments: nil),
            .init(index: 7, name: "Active", text: String(repeating: "The complete saved chapter remains readable.\n", count: repetitions),
                  html: "<html><body><p>" + String(repeating: "The complete saved chapter remains readable.<br/>", count: repetitions)
                    + "</p></body></html>", css: nil, charCount: nil, segments: nil),
        ])
        let source = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(payload).write(to: source, options: .atomic)
        let store = PreparedReaderChapterStore(directory: root.appendingPathComponent("chapters"))
        try await store.write(bookID: id, chapterOrdinal: 1, fulltextURL: source)
        let settings = AppSettings(defaults: defaults)
        settings.readerTheme = .light
        settings.readerLayout = layout
        let rendererStore = PreparedChapterArchiveStore(directory: root.appendingPathComponent("rendered"))
        let preparingRenderer = PreparedChapterRenderer(store: rendererStore)
        let preparedRendering = try XCTUnwrap(preparingRenderer.render(bookID: id, chapterIndex: 1,
            chapter: payload.chapters[1], settings: settings))
        let activeText = preparedRendering.string
        await preparingRenderer.flush()
        let reopenedRenderer = PreparedChapterRenderer(store: rendererStore)
        let stageNames = ReaderOpenStageNames()
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.\(id)")
        ReaderProgressStore.evict(bookId: id)
        ReaderProgressStore.save(bookId: id, chapterIndex: 1, offsetFraction: 0.6)

        var releaseCatalog: AsyncStream<Void>.Continuation!
        let catalogGate = AsyncStream<Void> { releaseCatalog = $0 }
        let catalogRequested = expectation(description: "Catalog hydration starts after the prepared chapter is visible")
        let controlsReady = expectation(description: "Reader controls become usable after opening gesture deferral ends")
        let hydratedPayload = mismatchedCatalog
            ? EbookFulltext(jobId: id, bookTitle: "Changed title", bookAuthor: "Author", chapters: payload.chapters)
            : payload
        let reader: @Sendable (String) async -> EbookFulltext? = { _ in
            catalogRequested.fulfill()
            for await _ in catalogGate { break }
            return hydratedPayload
        }
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let previousDefaults = keys.map { UserDefaults.standard.object(forKey: $0) }
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        defer {
            releaseCatalog.finish()
            player.stop()
            ReaderProgressStore.evict(bookId: id)
            LocalFulltextCache.evict(bookId: id)
            defaults.removePersistentDomain(forName: id)
            for (key, value) in zip(keys, previousDefaults) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }

        let known = Set(LatencyObservationStore.shared.snapshot().map(\.id))
        let controller = BookOpenScreenController(
            book: book,
            library: LibraryStore(defaults: defaults, defaultsKey: "library.\(id)"),
            settings: settings,
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks.\(id)"),
            player: player,
            preparedRenderer: reopenedRenderer,
            preparedChapterStore: store,
            preparedFulltextReader: reader,
            openStageObserver: { name, _ in
                stageNames.append(name)
                if name == "controls_usable" { controlsReady.fulfill() }
            },
            deferInitialReaderGestures: !launchRestore
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }

        await fulfillment(of: [catalogRequested], timeout: 3)
        await fulfillment(of: [controlsReady], timeout: 3)
        let textView = try XCTUnwrap(findTextView(controller.view))
        XCTAssertEqual(textView.attributedText.string, activeText,
                       "The validated active chapter must appear while the complete catalog is still suspended")
        XCTAssertEqual(stageNames.count("prepared_render_reused"), 1,
                       "The attributed chapter restored from disk must be attached directly")
        XCTAssertEqual(stageNames.count("prepared_render_generated"), 0,
                       "The restored attributed chapter must not be decoded or generated a second time")
        XCTAssertEqual(stageNames.count("projection_read_scheduled"), 1,
                       "The disk projection read should start before the MainActor load task resumes")
        XCTAssertEqual(stageNames.count("projection_snapshot_validated"), 1,
                       "The projection must be source and catalog validated before presentation starts")
        XCTAssertEqual(stageNames.count("prepared_renderer_restore_started"), 1)
        XCTAssertEqual(stageNames.count("prepared_renderer_restore_completed"), 1)
        let recordedStages = stageNames.snapshot()
        let projectionStarted = try XCTUnwrap(recordedStages.firstIndex(of: "projection_presentation_started"))
        let preparedRenderIndex = try XCTUnwrap(recordedStages.firstIndex(of: "prepared_render_reused"))
        let chapterMounted = try XCTUnwrap(recordedStages.firstIndex(of: "projection_chapter_mounted"))
        let projectionLayoutCompleted = try XCTUnwrap(recordedStages.firstIndex(of: "projection_layout_completed"))
        let readableIndex = try XCTUnwrap(recordedStages.firstIndex(of: "readable_content"))
        XCTAssertLessThan(projectionStarted, preparedRenderIndex)
        XCTAssertLessThan(preparedRenderIndex, chapterMounted)
        XCTAssertLessThan(chapterMounted, projectionLayoutCompleted)
        XCTAssertLessThan(projectionLayoutCompleted, readableIndex)
        XCTAssertEqual(recordedStages[preparedRenderIndex..<readableIndex]
            .filter { $0 == "reader_viewport_text_layout_committed" }.count, 1,
            "The prepared chapter must be measured once against the committed viewport before readiness")
        XCTAssertGreaterThan(try XCTUnwrap(recordedStages.firstIndex(of: "controls_usable")), readableIndex,
                             "Controls are ready only after readable content")
        let rootCallbackCompleted = try XCTUnwrap(
            recordedStages.firstIndex(of: "reader_loading_root_callback_completed")
        )
        let controlsEnabled = try XCTUnwrap(recordedStages.firstIndex(of: "reader_controls_enabled"))
        let controlsUsable = try XCTUnwrap(recordedStages.firstIndex(of: "controls_usable"))
        XCTAssertLessThan(rootCallbackCompleted, controlsEnabled)
        XCTAssertLessThan(controlsEnabled, controlsUsable)
        XCTAssertFalse(controller.isLoadingBookContent)
        let loadingOverlay = try XCTUnwrap(descendants(controller.view)
            .first(where: { $0.accessibilityIdentifier == "reader.loadingOverlay" }))
        XCTAssertTrue(loadingOverlay.isHidden, "A measured one-page chapter must dismiss the loading cover")
        let activeScroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }
            .first(where: { $0.accessibilityIdentifier == "reader.viewport" }))
        if layout == .scrolling {
            XCTAssertTrue(activeScroll.isScrollEnabled, "The final reader mode must restore scrolling after loading")
        }
        XCTAssertEqual(controller.currentReaderChapterIndex, 6,
                       "Playback must use the active chapter's canonical EPUB index")
        let readable = LatencyObservationStore.shared.snapshot().contains {
            !known.contains($0.id) && $0.records.contains { $0.transition == .readableContent }
        }
        XCTAssertTrue(readable, "Prepared chapter readiness must precede catalog hydration")
        let controls = LatencyObservationStore.shared.snapshot().contains {
            !known.contains($0.id) && $0.records.contains { $0.transition == .controlsUsable }
        }
        XCTAssertTrue(controls, "A source-bound complete chapter catalog makes controls usable before body hydration")
        XCTAssertEqual(ReaderProgressStore.read(bookId: id)?.chapterIndex, 1)
        XCTAssertEqual(ReaderProgressStore.read(bookId: id)?.offsetFraction ?? -1, 0.6, accuracy: 0.001)
        let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }
            .first(where: { $0.accessibilityIdentifier == "reader.viewport" }))
        let scrollable = max(scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height, 0)
        if shortChapter {
            XCTAssertEqual(scrollable, 0, accuracy: 1,
                           "The short fixture must exercise readiness without a positive scroll range")
            XCTAssertEqual(controller.playbackChapterCatalog.map(\.title), ["Previous", "Active"])
            XCTAssertGreaterThan(scroll.bounds.width, 1)
            XCTAssertGreaterThan(scroll.bounds.height, 1)
        } else {
            XCTAssertGreaterThan(scrollable, 0)
        }
        XCTAssertEqual(scroll.contentOffset.y, scrollable * 0.6, accuracy: 3,
                       "The projected chapter must commit the saved position against its final viewport")
        if mismatchedCatalog {
            releaseCatalog.yield(())
            for _ in 0..<100 where textView.attributedText.string != activeText {
                await Task.yield()
            }
            XCTAssertEqual(textView.attributedText.string, activeText)
            XCTAssertEqual(ReaderProgressStore.read(bookId: id)?.chapterIndex, 1)
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func findTextView(_ view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView($0) }.first
    }
}
#endif
