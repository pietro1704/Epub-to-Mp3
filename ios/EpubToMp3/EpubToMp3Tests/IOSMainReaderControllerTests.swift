#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class IOSMainReaderControllerTests: XCTestCase {
    func testClosingReaderOverridesARegisteredFallbackBookID() throws {
        let suiteName = "main-reader-close-fallback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.register(defaults: [ReaderSessionState.currentlyReadingBookIDKey: "stale-book"])
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ReaderSessionState.setCurrentlyReading(bookID: nil, defaults: defaults)
        ReaderSessionState.setCurrentlyReading(bookID: nil, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey), "")
    }

    func testClosingReaderClearsInjectedSessionAndCallsLibraryAction() throws {
        let id = "main-reader-close-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let persistedValue = UserDefaults.standard.object(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let book = BookEntity(id: id, title: "Close reader", bookmark: Data([1]),
                              displayFilename: "close.epub", addedAt: Date())
        let libraryKey = "library.\(id)"
        defaults.set(try JSONEncoder().encode([book]), forKey: libraryKey)
        let library = LibraryStore(defaults: defaults, defaultsKey: libraryKey)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        ReaderSessionState.setCurrentlyReading(bookID: id, defaults: defaults)
        var didBrowseLibrary = false
        let reader = MainReaderScreenController(
            library: library,
            settings: AppSettings(defaults: defaults),
            player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            bookmarkStore: BookmarkStore(defaults: defaults, storageKey: "bookmarks.\(id)"),
            onBrowseLibrary: {
                didBrowseLibrary = true
                ReaderSessionState.setCurrentlyReading(bookID: nil, defaults: defaults)
            },
            sessionDefaults: defaults
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = reader
        window.makeKeyAndVisible()
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()

        defer {
            window.isHidden = true
            window.rootViewController = nil
            player.stop()
            defaults.removePersistentDomain(forName: id)
            UserDefaults.standard.set(persistedValue, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        }

        let navigationBar = try XCTUnwrap(reader.view.subviews.compactMap { $0 as? UINavigationBar }.first)
        let closeButton = try XCTUnwrap(navigationBar.items?.first?.leftBarButtonItem)
        _ = closeButton.target?.perform(closeButton.action, with: closeButton)

        XCTAssertTrue(didBrowseLibrary)
        XCTAssertNil(defaults.string(forKey: ReaderSessionState.currentlyReadingBookIDKey))
    }

    func testChromeRoundTripRebindsTheInstalledReaderAndRestoresItsRawViewportOffset() async throws {
        let id = "main-reader-chrome-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let sharedKeys = [ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.readerCurrentSentenceIdDefaultsKey, "readerProgress.v1", "readerWarmBookIDs.v1"]
        let saved = sharedKeys.map { UserDefaults.standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
            "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
            "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
            "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let savedWidget = widgetKeys.map { widget?.object(forKey: $0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: root.appendingPathComponent("rendered")))
        addTeardownBlock {
            await renderer.flush()
            try? FileManager.default.removeItem(at: root)
        }
        let book = BookEntity(id: id, title: "Chrome fixture", bookmark: Data([1]),
            displayFilename: "fixture.epub", addedAt: Date())
        let libraryKey = "library.\(id)"
        defaults.set(try JSONEncoder().encode([book]), forKey: libraryKey)
        ReaderSessionState.setCurrentlyReading(bookID: id, defaults: defaults)
        let library = LibraryStore(defaults: defaults, defaultsKey: libraryKey, importDirectory: root)
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .scrolling
        let bookmarks = BookmarkStore(defaults: defaults, storageKey: "bookmarks")
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let payload = EbookFulltext(jobId: id, bookTitle: book.title, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Chapter", text: String(repeating: "A complete line of readable fixture text.\n\n", count: 250),
                html: nil, css: nil, charCount: nil, segments: nil),
        ])
        let chapterStore = PreparedReaderChapterStore(directory: root.appendingPathComponent("chapters"))
        let persisted = expectation(description: "The current generation delegates its exact prepared payload")
        let main = MainReaderScreenController(library: library, settings: settings, player: player,
            playerPresentation: PlayerPresentation(defaults: defaults), bookmarkStore: bookmarks,
            onBrowseLibrary: nil, sessionDefaults: defaults,
            readerControllerFactory: { book, deferred in
                BookOpenScreenController(book: book, library: library, settings: settings,
                    bookmarkStore: bookmarks, player: player, preparedRenderer: renderer,
                    preparedChapterStore: chapterStore,
                    preparedFulltextReader: { requested in requested == id ? payload : nil },
                    preparedFulltextWriter: { written, bookID, ordinal, store in
                        XCTAssertEqual(written, payload)
                        XCTAssertEqual(bookID, id)
                        XCTAssertEqual(ordinal, 0)
                        XCTAssertTrue(store === chapterStore)
                        persisted.fulfill()
                    },
                    sessionDefaults: defaults, deferInitialReaderGestures: deferred)
            })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = main
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            player.stop()
            defaults.removePersistentDomain(forName: id)
            for (key, value) in zip(sharedKeys, saved) { UserDefaults.standard.set(value, forKey: key) }
            for (key, value) in zip(widgetKeys, savedWidget) { widget?.set(value, forKey: key) }
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let child = try XCTUnwrap(main.children.compactMap { $0 as? BookOpenScreenController }.first)
        let viewport = try XCTUnwrap(descendants(child.view).compactMap { $0 as? UIScrollView }
            .first { $0.accessibilityIdentifier == "reader.viewport" })
        for _ in 0..<200 {
            main.view.layoutIfNeeded()
            if !main.isLoadingBookContent, viewport.contentSize.height > viewport.bounds.height + 600 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await fulfillment(of: [persisted], timeout: 2)
        XCTAssertFalse(main.isLoadingBookContent)
        XCTAssertGreaterThan(viewport.contentSize.height, viewport.bounds.height + 600)
        let navigation = try XCTUnwrap(main.view.subviews.compactMap { $0 as? UINavigationBar }.first)
        let shownTop = child.view.frame.minY
        XCTAssertGreaterThan(shownTop, 0)
        let raw = CGPoint(x: 0, y: 257.375)
        viewport.setContentOffset(raw, animated: false)
        for hidden in [true, false, true, false] {
            main.captureReaderViewportTransition()
            XCTAssertTrue(main.applyReaderPresentation(.init(isReaderActive: true, isLoading: false, isChromeHidden: hidden)))
            // Applying presentation swaps constraints without committing transient geometry.
            let topConstraints = main.view.constraints.filter {
                ($0.firstItem as? UIView) === child.view && $0.firstAttribute == .top && $0.isActive
            }
            XCTAssertEqual(topConstraints.count, 1)
            let expectedAnchor: UIView = hidden ? main.view : navigation
            XCTAssertTrue((topConstraints.first?.secondItem as? UIView) === expectedAnchor)
            main.view.setNeedsLayout()
            main.view.layoutIfNeeded()
            main.completeReaderChromeLayoutTransition()
            // Completion restores only after the final child viewport has laid out.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertEqual(child.view.frame.minY, hidden ? 0 : shownTop, accuracy: 0.5)
            XCTAssertEqual(navigation.isHidden, hidden)
            XCTAssertEqual(viewport.contentOffset.y, raw.y, accuracy: 0.01)
            XCTAssertFalse(main.applyReaderPresentation(.init(isReaderActive: true, isLoading: false, isChromeHidden: hidden)),
                           "Repeating the committed chrome state must be idempotent.")
        }
        await renderer.flush()
    }

    func testOpenStageProfilerEmitsOneRelativeSummaryAtControlsReadiness() {
        let profiler = IOSReaderOpenStageProfiler()
        XCTAssertNil(profiler.record("ignored", at: 1_000_000))
        XCTAssertNil(profiler.record("reader_open_requested", at: 2_000_000))
        XCTAssertNil(profiler.record("reader_load_task_started", at: 8_000_000))
        XCTAssertEqual(
            profiler.record("controls_usable", at: 42_000_000),
            "reader_open_requested=0.0ms,reader_load_task_started=6.0ms,controls_usable=40.0ms"
        )
        XCTAssertNil(profiler.record("after_ready", at: 43_000_000))
    }

    func testRootStartupMarkerPreservesAnEarlierReaderOpenStart() {
        let profiler = IOSReaderOpenStageProfiler()
        XCTAssertNil(profiler.record("reader_open_requested", at: 10_000_000))
        XCTAssertNil(profiler.record("reader_load_task_scheduled", at: 12_000_000))
        profiler.begin("root_view_did_load_started", at: 80_000_000)
        XCTAssertEqual(
            profiler.record("controls_usable", at: 210_000_000),
            "reader_open_requested=0.0ms,reader_load_task_scheduled=2.0ms,root_view_did_load_started=70.0ms,controls_usable=200.0ms"
        )
    }

    func testReentrantRefreshDuringBookControllerCreationDoesNotOpenTheBookTwice() throws {
        let id = "main-reader-reentrant-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        let book = BookEntity(id: id, title: "Reentrant reader", bookmark: Data([1]),
                              displayFilename: "reentrant.epub", addedAt: Date())
        let libraryKey = "library.\(id)"
        defaults.set(try JSONEncoder().encode([book]), forKey: libraryKey)
        let library = LibraryStore(defaults: defaults, defaultsKey: libraryKey)
        let settings = AppSettings(defaults: defaults)
        let bookmarkStore = BookmarkStore(defaults: defaults, storageKey: "bookmarks.\(id)")
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
        let payload = EbookFulltext(jobId: id, bookTitle: book.title, bookAuthor: nil, chapters: [
            .init(index: 1, name: "Chapter", text: "Readable test chapter.", html: nil,
                  css: nil, charCount: 23, segments: nil),
        ])
        let preparedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let renderer = PreparedChapterRenderer(store: PreparedChapterArchiveStore(directory: preparedRoot))
        addTeardownBlock {
            await renderer.flush()
            try? FileManager.default.removeItem(at: preparedRoot)
        }
        ReaderSessionState.setCurrentlyReading(bookID: id, defaults: defaults)

        let persistedKeys = [ReaderSessionState.currentlyReadingBookIDKey,
                             AudioPlayer.currentBookIDDefaultsKey,
                             AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                             AudioPlayer.readerCurrentPageRatioDefaultsKey,
                             AudioPlayer.readerCurrentSentenceIdDefaultsKey, "readerProgress.v1", "readerWarmBookIDs.v1"]
        let persistedValues = persistedKeys.map { UserDefaults.standard.object(forKey: $0) }
        var mainReader: MainReaderScreenController!
        var constructionCount = 0
        var shouldDeferInitialGesture: Bool?
        var didReenter = false
        mainReader = MainReaderScreenController(
            library: library,
            settings: settings,
            player: player,
            playerPresentation: PlayerPresentation(defaults: defaults),
            bookmarkStore: bookmarkStore,
            onBrowseLibrary: nil,
            sessionDefaults: defaults,
            readerControllerFactory: { book, shouldDefer in
                constructionCount += 1
                shouldDeferInitialGesture = shouldDefer
                if !didReenter {
                    didReenter = true
                    mainReader.update(library: library, settings: settings, onBrowseLibrary: nil)
                }
                return BookOpenScreenController(
                    book: book,
                    library: library,
                    settings: settings,
                    bookmarkStore: bookmarkStore,
                    player: player,
                    preparedRenderer: renderer,
                    preparedChapterStore: PreparedReaderChapterStore(directory: preparedRoot.appendingPathComponent("chapters")),
                    preparedFulltextReader: { _ in payload },
                    preparedFulltextWriter: { _, _, _, _ in },
                    sessionDefaults: defaults,
                    deferInitialReaderGestures: shouldDefer
                )
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = mainReader
        window.makeKeyAndVisible()
        mainReader.view.setNeedsLayout()
        mainReader.view.layoutIfNeeded()

        defer {
            window.isHidden = true
            window.rootViewController = nil
            player.stop()
            mainReader = nil
            defaults.removePersistentDomain(forName: id)
            for (key, value) in zip(persistedKeys, persistedValues) {
                UserDefaults.standard.set(value, forKey: key)
            }
        }

        XCTAssertEqual(constructionCount, 1,
                       "A same-book render reentered during child setup must reuse the pending reader")
        XCTAssertEqual(shouldDeferInitialGesture, false,
                       "A reader restored from the launch session has no opening tap to protect")
    }
}
#endif
