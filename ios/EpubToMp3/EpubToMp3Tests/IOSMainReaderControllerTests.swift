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
        LocalFulltextCache.save(payload, bookId: id)
        ReaderSessionState.setCurrentlyReading(bookID: id, defaults: defaults)

        let persistedKeys = [ReaderSessionState.currentlyReadingBookIDKey,
                             AudioPlayer.currentBookIDDefaultsKey,
                             AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                             AudioPlayer.readerCurrentPageRatioDefaultsKey,
                             AudioPlayer.readerCurrentSentenceIdDefaultsKey]
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
            LocalFulltextCache.evict(bookId: id)
            ReaderProgressStore.evict(bookId: id)
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
