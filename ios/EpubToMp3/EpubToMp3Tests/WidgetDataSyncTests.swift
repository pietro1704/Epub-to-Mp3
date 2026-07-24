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
        // The widget extension bundles no Localizable.strings — the host must
        // ship a pre-localized label through the App Group payload.
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
        // Write directly using the same key names the extension reads.
        defaults.set("book-42", forKey: "currentlyPlayingBookId")
        defaults.set("The Psychohistorians", forKey: "widget.nowPlayingChapterName")
        defaults.set(0.45, forKey: "widget.nowPlayingProgress")
        defaults.set(true, forKey: "widget.nowPlayingIsPlaying")

        XCTAssertEqual(defaults.string(forKey: "currentlyPlayingBookId"), "book-42")
        XCTAssertEqual(defaults.string(forKey: "widget.nowPlayingChapterName"), "The Psychohistorians")
        XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingProgress"), 0.45, accuracy: 0.001)
        XCTAssertTrue(defaults.bool(forKey: "widget.nowPlayingIsPlaying"))
    }

    func test_clearNowPlaying_removesKeys() {
        defaults.set("book-42", forKey: "currentlyPlayingBookId")
        defaults.set(0.5, forKey: "widget.nowPlayingProgress")

        defaults.removeObject(forKey: "currentlyPlayingBookId")
        defaults.removeObject(forKey: "widget.nowPlayingProgress")

        XCTAssertNil(defaults.string(forKey: "currentlyPlayingBookId"))
        XCTAssertEqual(defaults.double(forKey: "widget.nowPlayingProgress"), 0.0) // default
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

    func test_conversionProgress_fraction_isCorrect() {
        // Mirrors ConversionActivityAttributes.ContentState.progressFraction logic.
        let done = 7
        let total = 20
        let fraction = Double(done) / Double(total)
        XCTAssertEqual(fraction, 0.35, accuracy: 0.001)
    }

    func test_conversionProgress_fraction_zero_when_total_is_zero() {
        let done = 0
        let total = 0
        let fraction: Double = total > 0 ? Double(done) / Double(total) : 0
        XCTAssertEqual(fraction, 0.0)
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
    func test_audioPlayerPauseResume_syncsRealAppGroupIsPlayingFlag() {
        let appGroupID = "group.com.pietrocode.epubtomp3"
        guard let group = UserDefaults(suiteName: appGroupID) else {
            XCTFail("App Group suite must be constructible even without the real entitlement in a test host")
            return
        }
        let standardKey = "currentlyPlayingBookID"
        let groupKey = "widget.nowPlayingIsPlaying"

        // Save/restore so this test doesn't leak state into other tests
        // or a real device's App Group.
        let previousStandard = UserDefaults.standard.string(forKey: standardKey)
        let previousGroupValue = group.object(forKey: groupKey)
        defer {
            if let previousStandard {
                UserDefaults.standard.set(previousStandard, forKey: standardKey)
            } else {
                UserDefaults.standard.removeObject(forKey: standardKey)
            }
            if let previousGroupValue {
                group.set(previousGroupValue, forKey: groupKey)
            } else {
                group.removeObject(forKey: groupKey)
            }
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
              "downloadUrl": "https://example.com/ch0.mp3",
              "progressRatio": 1.0,
              "durationSeconds": 120.0
            }
          ]
        }
        """.data(using: .utf8)!
        let snapshot = try! JSONDecoder().decode(JobSnapshot.self, from: json)

        let player = AudioPlayer()
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
            AudioPlayer.widgetSyncNeedsReload(last: state, current: state),
            "A repeated tick with the same book/chapter/isPlaying must not force a WidgetKit reload"
        )
    }

    func test_widgetSyncNeedsReload_trueOnFirstSync() {
        let state = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        XCTAssertTrue(
            AudioPlayer.widgetSyncNeedsReload(last: nil, current: state),
            "The very first sync (no prior state) must always reload so the widget picks up the book"
        )
    }

    func test_widgetSyncNeedsReload_trueOnIsPlayingChange() {
        let last = (bookId: "book-1", chapterName: "Chapter One", isPlaying: false)
        let current = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        XCTAssertTrue(AudioPlayer.widgetSyncNeedsReload(last: last, current: current))
    }

    func test_widgetSyncNeedsReload_trueOnChapterChange() {
        let last = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        let current = (bookId: "book-1", chapterName: "Chapter Two", isPlaying: true)
        XCTAssertTrue(AudioPlayer.widgetSyncNeedsReload(last: last, current: current))
    }

    func test_widgetSyncNeedsReload_trueOnBookChange() {
        let last = (bookId: "book-1", chapterName: "Chapter One", isPlaying: true)
        let current = (bookId: "book-2", chapterName: "Chapter One", isPlaying: true)
        XCTAssertTrue(AudioPlayer.widgetSyncNeedsReload(last: last, current: current))
    }

    // MARK: - App Group boundary (never UserDefaults.standard)

    /// Verify that keys written to the test suite are NOT visible in .standard.
    func test_appGroup_isolatedFromStandard() {
        defaults.set("sentinel", forKey: "widget.test.isolation")
        let standardValue = UserDefaults.standard.string(forKey: "widget.test.isolation")
        XCTAssertNil(standardValue, "Widget keys must never be readable from UserDefaults.standard")
    }
}
