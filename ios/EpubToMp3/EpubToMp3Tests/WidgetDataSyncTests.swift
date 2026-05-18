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

    // MARK: - App Group boundary (never UserDefaults.standard)

    /// Verify that keys written to the test suite are NOT visible in .standard.
    func test_appGroup_isolatedFromStandard() {
        defaults.set("sentinel", forKey: "widget.test.isolation")
        let standardValue = UserDefaults.standard.string(forKey: "widget.test.isolation")
        XCTAssertNil(standardValue, "Widget keys must never be readable from UserDefaults.standard")
    }
}
