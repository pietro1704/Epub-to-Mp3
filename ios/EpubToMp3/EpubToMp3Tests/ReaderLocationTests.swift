import XCTest
#if SWIFT_PACKAGE
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ReaderLocationTests: XCTestCase {
    func testReopenReadsLegacyKeysAndKeepsReaderAndPlayerBooksIndependent() throws {
        let suite = "reader-location-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.setPersistentDomain([
            "currentlyReadingBookID": "reading",
            "currentlyPlayingBookID": "playing",
            "currentlyPlayingChapterIndex": 18,
            "readerCurrentChapterIndex": 0,
            "readerCurrentPageRatio": 0.25,
            "readerCurrentSentenceId": "sentence"
        ], forName: suite)
        let reopened = ReaderLocation(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.readingBookID, "reading")
        XCTAssertEqual(reopened.playingBookID, "playing")
        XCTAssertEqual(reopened.playingChapter, 18)
        XCTAssertEqual(reopened.readerChapter, 0)
        XCTAssertEqual(reopened.pageRatio, 0.25)
        XCTAssertEqual(reopened.sentenceID, "sentence")
        reopened.setReaderAnchor(chapter: 3, pageRatio: 0)
        XCTAssertNil(defaults.object(forKey: "readerCurrentSentenceId"))
        XCTAssertEqual(defaults.object(forKey: "readerCurrentChapterIndex") as? Int, 3)
        XCTAssertEqual(defaults.object(forKey: "readerCurrentPageRatio") as? Double, 0)
        XCTAssertEqual(defaults.object(forKey: "currentlyPlayingChapterIndex") as? Int, 18)
        reopened.bindPlayingBook(nil, chapter: 0)
        XCTAssertNil(reopened.playingBookID)
        XCTAssertNil(reopened.playingChapter)
        XCTAssertEqual(reopened.readingBookID, "reading")
    }
}
