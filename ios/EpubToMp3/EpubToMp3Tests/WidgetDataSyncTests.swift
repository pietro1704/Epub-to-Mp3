import AVFoundation
import XCTest
@testable import EpubToMp3

/// Tests for WidgetDataSync App Group read/write round-trips.
///
/// These tests do NOT require a physical App Group entitlement — they inject
/// a test-suite UserDefaults instance directly, matching the same key names
/// used by WidgetDataSync and the widget extension.
final class WidgetDataSyncTests: XCTestCase {

    // MARK: - Helpers

    private let testSuiteName = "com.test.WidgetDataSyncTests.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: testSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: testSuiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Localized chapter label

    func test_localizedChapterLabel_delegatesToL10n() {
        // The host ships its localized label through the App Group payload.
        XCTAssertEqual(
            WidgetDataSync.localizedChapterLabel(chapterIndex: 4, totalChapters: 18),
            L10n.string("player.chapterOf", 5, 18)
        )
        XCTAssertEqual(
            WidgetDataSync.localizedChapterLabel(chapterIndex: 4, totalChapters: nil),
            L10n.string("player.chapter", 5)
        )
        XCTAssertEqual(
            WidgetDataSync.localizedChapterLabel(chapterIndex: 0, totalChapters: 0),
            L10n.string("player.chapter", 1)
        )
    }

    // MARK: - Now Playing round-trip

    func test_updateNowPlaying_writesAllKeys() {
        var reloads = 0
        WidgetDataSync.updateNowPlaying(bookId: "book-42", chapterName: "The Psychohistorians",
            author: "Isaac Asimov", progress: 0.45, isPlaying: true, positionSeconds: 30,
            durationSeconds: 60, chapterRemainingSeconds: 30, bookRemainingSeconds: 120,
            totalChapters: 18, defaults: defaults, reloadWidgets: {
                XCTAssertEqual(self.defaults.object(forKey: "widget.nowPlayingTotalChapters") as? Int, 18)
                reloads += 1
            })

        XCTAssertEqual(defaults.string(forKey: "currentlyPlayingBookId"), "book-42")
        XCTAssertEqual(defaults.string(forKey: "widget.nowPlayingChapterName"), "The Psychohistorians")
        XCTAssertEqual(defaults.string(forKey: "widget.nowPlayingAuthor"), "Isaac Asimov")
        XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingProgress"), 0.45, accuracy: 0.001)
        XCTAssertTrue(defaults.bool(forKey: "widget.nowPlayingIsPlaying"))
        XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingPositionSeconds"), 30)
        XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingDurationSeconds"), 60)
        XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingChapterRemainingSeconds"), 30)
        XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingBookRemainingSeconds"), 120)
        XCTAssertEqual(reloads, 1)
    }

    func test_clearNowPlaying_removesKeys() {
        defaults.set("keep", forKey: "unrelated")
        defaults.set(37, forKey: "widget.lastReadTotalChapters")
        let absentIDs: [String?] = [nil, ""]
        for absent in absentIDs {
            WidgetDataSync.updateNowPlaying(bookId: "book-42", chapterName: "Chapter", author: "Author",
                progress: 0.5, isPlaying: true, positionSeconds: 10, durationSeconds: 20,
                chapterRemainingSeconds: 10, bookRemainingSeconds: 60, totalChapters: 18,
                defaults: defaults, reloadWidgets: {})
            var reloads = 0

            WidgetDataSync.updateNowPlaying(bookId: absent, totalChapters: 999, defaults: defaults, reloadWidgets: {
                XCTAssertNil(self.defaults.object(forKey: "widget.nowPlayingTotalChapters"))
                reloads += 1
            })

            for key in ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
                        "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying", "widget.nowPlayingPositionSeconds",
                        "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
                        "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"] {
                XCTAssertNil(defaults.object(forKey: key), "Clearing must remove the complete Now Playing payload")
            }
            XCTAssertNil(NowPlayingProvider().loadNowPlaying(defaults: defaults).bookId)
            XCTAssertEqual(reloads, 1)
        }
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
        XCTAssertEqual(defaults.integer(forKey: "widget.lastReadTotalChapters"), 37)
    }

    func testNowPlayingReplacementDoesNotBorrowPreviousBooksChapterTotal() throws {
        try seedNowPlayingBooks()
        WidgetDataSync.updateNowPlaying(bookId: "book-a", totalChapters: 20, defaults: defaults, reloadWidgets: {})
        XCTAssertEqual(NowPlayingProvider().loadNowPlaying(defaults: defaults).totalChapters, 20)
        var reloads = 0

        WidgetDataSync.updateNowPlaying(bookId: "book-b", chapterName: "New chapter", totalChapters: nil,
                                       defaults: defaults, reloadWidgets: {
            XCTAssertEqual(self.defaults.string(forKey: "currentlyPlayingBookId"), "book-b")
            XCTAssertNil(self.defaults.object(forKey: "widget.nowPlayingTotalChapters"))
            reloads += 1
        })

        let entry = NowPlayingProvider().loadNowPlaying(defaults: defaults)
        XCTAssertEqual(entry.bookId, "book-b")
        XCTAssertEqual(entry.title, "Second book")
        XCTAssertEqual(entry.chapterName, "New chapter")
        XCTAssertNil(entry.totalChapters)
        XCTAssertEqual(reloads, 1)
    }

    func testSameBookUnknownChapterTotalReplacesPreviouslyKnownValue() throws {
        try seedNowPlayingBooks()
        WidgetDataSync.updateNowPlaying(bookId: "book-a", totalChapters: 20, defaults: defaults, reloadWidgets: {})

        WidgetDataSync.updateNowPlaying(bookId: "book-a", chapterName: "Current chapter", author: "Current author",
                                       isPlaying: true, totalChapters: nil, defaults: defaults, reloadWidgets: {})

        let entry = NowPlayingProvider().loadNowPlaying(defaults: defaults)
        XCTAssertEqual(entry.bookId, "book-a")
        XCTAssertEqual(entry.author, "Current author")
        XCTAssertTrue(entry.isPlaying)
        XCTAssertNil(entry.totalChapters)
        XCTAssertNil(defaults.object(forKey: "widget.nowPlayingTotalChapters"))
    }

    func testKnownChapterTotalsContinueToUpdateIncludingExplicitZero() throws {
        try seedNowPlayingBooks()
        for total in [12, 30, 0] {
            WidgetDataSync.updateNowPlaying(bookId: "book-a", totalChapters: total,
                                           defaults: defaults, reloadWidgets: {})

            XCTAssertEqual(defaults.object(forKey: "widget.nowPlayingTotalChapters") as? Int, total)
            XCTAssertEqual(NowPlayingProvider().loadNowPlaying(defaults: defaults).totalChapters, total)
        }
    }

    func testTimingPublicationClearsUnknownTotalAndRetainsCurrentBookMetadata() throws {
        try seedNowPlayingBooks()
        defaults.set(37, forKey: "widget.lastReadTotalChapters")
        WidgetDataSync.updateNowPlaying(bookId: "book-a", chapterName: "Current chapter", author: "Current author",
                                       isPlaying: true, totalChapters: 20, defaults: defaults, reloadWidgets: {})
        let totals: [Int?] = [nil, 15, nil]
        for total in totals {
            WidgetDataSync.updateNowPlayingTiming(positionSeconds: 40, durationSeconds: 100,
                chapterRemainingSeconds: 60, bookRemainingSeconds: 200, totalChapters: total, defaults: defaults)

            let entry = NowPlayingProvider().loadNowPlaying(defaults: defaults)
            XCTAssertEqual(entry.bookId, "book-a")
            XCTAssertEqual(entry.chapterName, "Current chapter")
            XCTAssertEqual(entry.author, "Current author")
            XCTAssertTrue(entry.isPlaying)
            XCTAssertEqual(entry.totalChapters, total)
            XCTAssertEqual(defaults.object(forKey: "widget.nowPlayingTotalChapters") as? Int, total)
            XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingPositionSeconds"), 40)
            XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingDurationSeconds"), 100)
            XCTAssertEqual(entry.chapterRemainingSeconds, 60)
            XCTAssertEqual(entry.bookRemainingSeconds, 200)
        }
        XCTAssertEqual(defaults.integer(forKey: "widget.lastReadTotalChapters"), 37)
    }

    func testUnavailableDefaultsDoesNotPublishReloadOrMutateOtherStorage() throws {
        try seedNowPlayingBooks()
        WidgetDataSync.updateNowPlaying(bookId: "book-a", totalChapters: 20, defaults: defaults, reloadWidgets: {})
        var reloads = 0

        WidgetDataSync.updateNowPlaying(bookId: "book-b", totalChapters: nil, defaults: nil, reloadWidgets: { reloads += 1 })
        WidgetDataSync.updateNowPlayingTiming(positionSeconds: 99, durationSeconds: 99,
            chapterRemainingSeconds: 99, bookRemainingSeconds: 99, totalChapters: nil, defaults: nil)

        let entry = NowPlayingProvider().loadNowPlaying(defaults: defaults)
        XCTAssertEqual(entry.bookId, "book-a")
        XCTAssertEqual(entry.totalChapters, 20)
        XCTAssertEqual(reloads, 0)
    }

    private func seedNowPlayingBooks() throws {
        let books = [["id": "book-a", "title": "First book"], ["id": "book-b", "title": "Second book"]]
        defaults.set(try JSONSerialization.data(withJSONObject: books), forKey: "library.books.v1")
    }

    // MARK: - isPlaying round-trip

    func test_isPlaying_toggleRoundTrip() {
        defaults.set(false, forKey: "widget.nowPlayingIsPlaying")
        XCTAssertFalse(defaults.bool(forKey: "widget.nowPlayingIsPlaying"))

        defaults.set(true, forKey: "widget.nowPlayingIsPlaying")
        XCTAssertTrue(defaults.bool(forKey: "widget.nowPlayingIsPlaying"))
    }

    // MARK: - Continue Reading round-trip

    func test_updateLastRead_writesAllKeys() {
        defaults.set("book-7", forKey: "widget.lastReadBookId")
        defaults.set(3, forKey: "widget.lastReadChapterIndex")
        defaults.set(18, forKey: "widget.lastReadTotalChapters")

        XCTAssertEqual(defaults.string(forKey: "widget.lastReadBookId"), "book-7")
        XCTAssertEqual(defaults.integer(forKey: "widget.lastReadChapterIndex"), 3)
        XCTAssertEqual(defaults.integer(forKey: "widget.lastReadTotalChapters"), 18)
    }

    // MARK: - Conversion progress round-trip

    func test_conversionProgress_writesAllKeys() {
        defaults.set("Foundation", forKey: "widget.conversion.bookTitle")
        defaults.set(5, forKey: "widget.conversion.chaptersDone")
        defaults.set(20, forKey: "widget.conversion.chaptersTotal")
        defaults.set("Part II: The Encyclopedists", forKey: "widget.conversion.currentChapterName")

        XCTAssertEqual(defaults.string(forKey: "widget.conversion.bookTitle"), "Foundation")
        XCTAssertEqual(defaults.integer(forKey: "widget.conversion.chaptersDone"), 5)
        XCTAssertEqual(defaults.integer(forKey: "widget.conversion.chaptersTotal"), 20)
        XCTAssertEqual(
            defaults.string(forKey: "widget.conversion.currentChapterName"),
            "Part II: The Encyclopedists"
        )
    }

    func testConversionActivityUsesRealSharedProgressAndClampsBounds() {
        XCTAssertEqual(ConversionActivityProgress(chaptersDone: 7, chaptersTotal: 20).progressFraction, 0.35, accuracy: 0.001)
        XCTAssertEqual(ConversionActivityProgress(chaptersDone: 0, chaptersTotal: 0).progressFraction, 0)
        XCTAssertEqual(ConversionActivityProgress(chaptersDone: 8, chaptersTotal: 2).progressFraction, 1)
        XCTAssertEqual(ConversionActivityProgress(chaptersDone: 0, chaptersTotal: 4, progressPercent: 12.5).progressFraction, 0.125, accuracy: 0.001)
        XCTAssertEqual(ConversionActivityProgress(chaptersDone: 1, chaptersTotal: 4, phase: .completed).progressFraction, 1)
    }

    func testConversionActivityReadsLegacyPayloadAndLocalizesTerminalStates() throws {
        let legacy = Data(#"{"chaptersDone":2,"chaptersTotal":8,"currentChapterName":null}"#.utf8)
        let progress = try JSONDecoder().decode(ConversionActivityProgress.self, from: legacy)
        XCTAssertEqual(progress.progressFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(progress.statusLocalizationKey, "liveActivity.converting")
        for phase in [ConversionActivityPhase.cancelled, .failed, .completed] {
            let state = ConversionActivityProgress(chaptersDone: 2, chaptersTotal: 8, phase: phase)
            XCTAssertTrue(phase.isTerminal)
            XCTAssertEqual(state.statusLocalizationKey, "liveActivity." + phase.rawValue)
            XCTAssertEqual(state.statusLabel, "2 / 8")
        }
    }

    // MARK: - Library key

    func test_libraryKey_roundTrip() throws {
        struct MinimalBook: Codable, Equatable {
            let id: String
            let title: String
        }
        let books = [MinimalBook(id: "b1", title: "Dune"), MinimalBook(id: "b2", title: "1984")]
        let data = try JSONEncoder().encode(books)
        defaults.set(data, forKey: "library.books.v1")

        let loaded = defaults.data(forKey: "library.books.v1")
        XCTAssertNotNil(loaded)
        let decoded = try JSONDecoder().decode([MinimalBook].self, from: loaded!)
        XCTAssertEqual(decoded, books)
    }

    // MARK: - AudioPlayer -> widget isPlaying sync (regression)

    /// Regression for: the widget showed "pause" forever because only
    /// `PlaybackBindingStore.setCurrentlyPlaying` (fired once, on book-open)
    /// wrote `widget.nowPlayingIsPlaying`, and it always wrote `true`.
    /// `AudioPlayer.pause()`/`resume()` must keep the real App Group flag
    /// in sync via `updateNowPlayingInfo() -> syncWidgetNowPlaying()`.
    @MainActor
    func test_audioPlayerPauseResume_syncsRealAppGroupIsPlayingFlag() throws {
        let appGroupID = "group.com.pietrocode.epubtomp3"
        guard let group = UserDefaults(suiteName: appGroupID) else {
            XCTFail("App Group suite must be constructible even without the real entitlement in a test host")
            return
        }
        let standardKey = AudioPlayer.currentBookIDDefaultsKey
        let groupKey = "widget.nowPlayingIsPlaying"
        let standardKeys = [standardKey, AudioPlayer.currentChapterIndexDefaultsKey,
            ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
            AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let groupKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName", "widget.nowPlayingAuthor",
            "widget.nowPlayingProgress", groupKey, "widget.nowPlayingPositionSeconds",
            "widget.nowPlayingDurationSeconds", "widget.nowPlayingChapterRemainingSeconds",
            "widget.nowPlayingBookRemainingSeconds", "widget.nowPlayingTotalChapters"]
        let previousStandard = standardKeys.map { UserDefaults.standard.object(forKey: $0) }
        let previousGroup = groupKeys.map { group.object(forKey: $0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("widget-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for (key, value) in zip(standardKeys, previousStandard) { UserDefaults.standard.set(value, forKey: key) }
            for (key, value) in zip(groupKeys, previousGroup) { group.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        // A silent, local WAV exercises the real queue without network access.
        let source = root.appendingPathComponent("silent.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: 800)
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        UserDefaults.standard.set("book-sync-test", forKey: standardKey)

        let json = """
        {
          "jobId": "widget-sync-test-job",
          "state": "finished",
          "bookTitle": "Foundation",
          "bookAuthor": "Isaac Asimov",
          "progressPercent": 100.0,
          "chaptersTotal": 1,
          "chaptersCompleted": 1,
          "chapterProgress": [
            {
              "index": 0,
              "name": "Prologue",
              "status": "completed",
              "downloadUrl": "\(source.absoluteString)",
              "progressRatio": 1.0,
              "durationSeconds": 120.0
            }
          ]
        }
        """.data(using: .utf8)!
        let snapshot = try! JSONDecoder().decode(JobSnapshot.self, from: json)

        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
            artifactStore: LocalAudioArtifactStore(root: root.appendingPathComponent("artifacts")))
        defer { player.stop() }
        player.updateSnapshot(snapshot)
        player.resume()
        XCTAssertTrue(
            group.bool(forKey: groupKey),
            "resume() must flip the App Group isPlaying flag to true"
        )

        player.pause()
        XCTAssertFalse(
            group.bool(forKey: groupKey),
            "pause() must flip the App Group isPlaying flag back to false — this is the exact bug where the widget kept showing a pause button after the user paused"
        )
    }

    // MARK: - AudioPlayer widget-reload throttle (regression)

    /// Regression for: `syncWidgetNowPlaying()` ran on every ~1Hz Now
    /// Playing refresh during playback and always called the RELOADING
    /// `WidgetDataSync.updateNowPlaying`, which fires three
    /// `WidgetCenter.reloadTimelines` XPC calls to widgetkitd. Under
    /// sustained playback this queued reload work every second; a widget
    /// button tap (which itself triggers another `updateNowPlayingInfo()`
    /// via `resume()`/`togglePlayPause()`) landed on top of an already
    /// backlogged queue and presented as the app "traves e fica pesado"
    /// when trying to start playback from the widget. The fix reloads only
    /// when book/chapter/isPlaying actually changed; bare progress ticks
    /// use the non-reloading `updateNowPlayingProgress`.
    func test_widgetSyncNeedsReload_falseForUnchangedProgressTick() {
        let state = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        XCTAssertFalse(
            NowPlayingPublication.widgetSyncNeedsReload(last: state, current: state),
            "A repeated tick with the same book/chapter/isPlaying must not force a WidgetKit reload"
        )
    }

    func test_widgetSyncNeedsReload_trueOnFirstSync() {
        let state = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        XCTAssertTrue(
            NowPlayingPublication.widgetSyncNeedsReload(last: nil, current: state),
            "The very first sync (no prior state) must always reload so the widget picks up the book"
        )
    }

    func test_widgetSyncNeedsReload_trueOnIsPlayingChange() {
        let last = (bookId: "book-1", chapterName: "Chapter One", isPlaying: false)
        let current = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        XCTAssertTrue(NowPlayingPublication.widgetSyncNeedsReload(last: last, current: current))
    }

    func test_widgetSyncNeedsReload_trueOnChapterChange() {
        let last = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        let current = (bookId: "book-1", chapterName: "Chapter Two", isPlaying: true)
        XCTAssertTrue(NowPlayingPublication.widgetSyncNeedsReload(last: last, current: current))
    }

    func test_widgetSyncNeedsReload_trueOnBookChange() {
        let last = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        let current = (bookId: "book-2", chapterName: "Chapter One", isPlaying: true)
        XCTAssertTrue(NowPlayingPublication.widgetSyncNeedsReload(last: last, current: current))
    }

    // MARK: - App Group boundary (never UserDefaults.standard)

    /// Verify that keys written to the test suite are NOT visible in .standard.
    func test_appGroup_isolatedFromStandard() {
        defaults.set("sentinel", forKey: "widget.test.isolation")
        let standardValue = UserDefaults.standard.string(forKey: "widget.test.isolation")
        XCTAssertNil(standardValue, "Widget keys must never be readable from UserDefaults.standard")
    }
}
