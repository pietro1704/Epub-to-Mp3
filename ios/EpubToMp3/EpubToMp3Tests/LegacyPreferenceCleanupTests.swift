import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class LegacyPreferenceCleanupTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "legacy-preference-cleanup-\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func seedLegacyValues(standard: UserDefaults, appGroup: UserDefaults) {
        standard.set("http://192.168.0.10:8000", forKey: "backendURL")
        standard.set(true, forKey: "useEmbeddedRuntime")
        standard.set(true, forKey: "allowCellularAudioConversion")
        standard.set(Int64(4_000_000_000), forKey: "offlineCacheBudgetBytes")
        standard.set(3600.0, forKey: "offlineCacheTTLSeconds")
        appGroup.set("book-7", forKey: "widget.lastReadBookId")
        appGroup.set(3, forKey: "widget.lastReadChapterIndex")
        appGroup.set(18, forKey: "widget.lastReadTotalChapters")
        appGroup.set("Chapter 4 of 18", forKey: "widget.lastReadChapterLabel")
        appGroup.set("Foundation", forKey: "widget.conversion.bookTitle")
        appGroup.set(5, forKey: "widget.conversion.chaptersDone")
        appGroup.set(20, forKey: "widget.conversion.chaptersTotal")
        appGroup.set("Part II", forKey: "widget.conversion.currentChapterName")
    }

    func testRemovesOnlyRetiredKeysAndPreservesUnmigratableAndCurrentData() throws {
        let standard = try makeDefaults()
        let appGroup = try makeDefaults()
        seedLegacyValues(standard: standard, appGroup: appGroup)
        // Values that must survive: unmigratable reader positions, the retired
        // conversion queue, current preferences and current widget payloads.
        standard.set(12, forKey: "readPos_ch_book-7")
        standard.set(40, forKey: "readPos_pg_book-7")
        let queue = Data(#"{"version":1,"requests":[{"bookID":"book-7"}]}"#.utf8)
        standard.set(queue, forKey: "localAudioConversionScheduler.queue.v1")
        standard.set(Data("primary".utf8), forKey: "primaryTtsSelection")
        appGroup.set("book-7", forKey: "currentlyPlayingBookId")
        appGroup.set(Data("[]".utf8), forKey: "library.books.v1")

        let outcome = LegacyPreferenceCleanup.runIfNeeded(standard: standard, appGroup: appGroup)

        XCTAssertEqual(Set(outcome.standardKeysRemoved), Set(LegacyPreferenceCleanup.retiredStandardKeys))
        XCTAssertEqual(Set(outcome.appGroupKeysRemoved), Set(LegacyPreferenceCleanup.retiredAppGroupKeys))
        XCTAssertTrue(outcome.standardCompleted)
        XCTAssertTrue(outcome.appGroupCompleted)
        for key in LegacyPreferenceCleanup.retiredStandardKeys { XCTAssertNil(standard.object(forKey: key), key) }
        for key in LegacyPreferenceCleanup.retiredAppGroupKeys { XCTAssertNil(appGroup.object(forKey: key), key) }
        XCTAssertEqual(standard.integer(forKey: "readPos_ch_book-7"), 12)
        XCTAssertEqual(standard.integer(forKey: "readPos_pg_book-7"), 40)
        XCTAssertEqual(standard.data(forKey: "localAudioConversionScheduler.queue.v1"), queue)
        XCTAssertEqual(standard.data(forKey: "primaryTtsSelection"), Data("primary".utf8))
        XCTAssertEqual(appGroup.string(forKey: "currentlyPlayingBookId"), "book-7")
        XCTAssertEqual(appGroup.data(forKey: "library.books.v1"), Data("[]".utf8))
    }

    func testSecondRunIsANoOpAndNeverTouchesLaterWrites() throws {
        let standard = try makeDefaults()
        let appGroup = try makeDefaults()
        seedLegacyValues(standard: standard, appGroup: appGroup)
        LegacyPreferenceCleanup.runIfNeeded(standard: standard, appGroup: appGroup)
        // A value written after the one-shot step (for example by a downgraded
        // build) belongs to that writer; the completed step must not repeat.
        standard.set("http://later", forKey: "backendURL")
        appGroup.set("book-9", forKey: "widget.lastReadBookId")

        let second = LegacyPreferenceCleanup.runIfNeeded(standard: standard, appGroup: appGroup)

        XCTAssertEqual(second.standardKeysRemoved, [])
        XCTAssertEqual(second.appGroupKeysRemoved, [])
        XCTAssertTrue(second.standardCompleted)
        XCTAssertTrue(second.appGroupCompleted)
        XCTAssertEqual(standard.string(forKey: "backendURL"), "http://later")
        XCTAssertEqual(appGroup.string(forKey: "widget.lastReadBookId"), "book-9")
    }

    func testUnavailableAppGroupIsCleanedOnALaterLaunch() throws {
        let standard = try makeDefaults()
        let appGroup = try makeDefaults()
        seedLegacyValues(standard: standard, appGroup: appGroup)

        let first = LegacyPreferenceCleanup.runIfNeeded(standard: standard, appGroup: nil)
        XCTAssertTrue(first.standardCompleted)
        XCTAssertFalse(first.appGroupCompleted)
        XCTAssertEqual(appGroup.string(forKey: "widget.lastReadBookId"), "book-7")
        XCTAssertEqual(appGroup.integer(forKey: LegacyPreferenceCleanup.versionKey), 0)

        let second = LegacyPreferenceCleanup.runIfNeeded(standard: standard, appGroup: appGroup)
        XCTAssertEqual(second.standardKeysRemoved, [])
        XCTAssertEqual(Set(second.appGroupKeysRemoved), Set(LegacyPreferenceCleanup.retiredAppGroupKeys))
        XCTAssertTrue(second.appGroupCompleted)
    }

    func testFreshInstallOnlyRecordsCompletion() throws {
        let standard = try makeDefaults()
        let appGroup = try makeDefaults()
        let outcome = LegacyPreferenceCleanup.runIfNeeded(standard: standard, appGroup: appGroup)
        XCTAssertEqual(outcome, .init(standardKeysRemoved: [], appGroupKeysRemoved: [],
                                      standardCompleted: true, appGroupCompleted: true))
        XCTAssertEqual(standard.integer(forKey: LegacyPreferenceCleanup.versionKey), 1)
        XCTAssertEqual(appGroup.integer(forKey: LegacyPreferenceCleanup.versionKey), 1)
    }
}
