import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class BookPronunciationTests: XCTestCase {
    func testExplicitEditsRoundTripAndStayIsolatedPerBook() throws {
        let suite = "BookPronunciationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookPronunciationStore(defaults: defaults)
        let rules = try BookPronunciationDictionary.parse("Tolkien = Tólkien\nDr. = Doutor")
        XCTAssertEqual(store.load(bookID: "book-a").rules.count, 0)
        try store.save(rules, bookID: "book-a")
        XCTAssertEqual(store.load(bookID: "book-a"), rules)
        XCTAssertEqual(store.load(bookID: "book-b").rules.count, 0)
        XCTAssertThrowsError(try BookPronunciationDictionary.parse("invalid line"))
        XCTAssertThrowsError(try BookPronunciationDictionary.parse("name = one\nname = two"))
        XCTAssertEqual(store.load(bookID: "book-a"), rules, "invalid edits preserve saved pronunciation")
        try store.save(BookPronunciationDictionary(), bookID: "book-a")
        XCTAssertEqual(store.load(bookID: "book-a").rules.count, 0)
    }

    func testRenderEstimateDoesNotInventRemainingTime() throws {
        let unknown = try JSONDecoder().decode(RenderProgressPresentation.self, from: Data(
            #"{"fraction":0.25,"etaSeconds":null,"freshCharsPerSecond":null,"cachedSegments":1}"#.utf8))
        XCTAssertEqual(unknown.label, L10n.string("bookDetail.progressPercent", 25))
        let measured = try JSONDecoder().decode(RenderProgressPresentation.self, from: Data(
            #"{"fraction":0.5,"etaSeconds":61,"freshCharsPerSecond":10,"cachedSegments":2}"#.utf8))
        XCTAssertEqual(measured.label, L10n.string("bookProgress.estimate", 50, 2))
    }

    func testSelectedJobSuccessDoesNotClaimACompleteBook() throws {
        let envelope: [String: Any] = ["manifest": ["jobId": "selected", "title": "Book", "author": "Author",
            "sourceChaptersTotal": 20, "chapters": [["sourceIndex": 7, "title": "Chapter 8",
                "filename": "chapter.mp3", "textChars": 50, "textOffset": 10]]]]
        let result = RustConversionCoordinator.Result(jobID: "selected",
            manifestJSON: try JSONSerialization.data(withJSONObject: envelope), outputDirectory: URL(fileURLWithPath: "/fixture"))
        let snapshot = try result.snapshot()
        XCTAssertEqual(snapshot.state, "finished", "The selected job succeeded")
        XCTAssertEqual(snapshot.isCompleteBookAudio, false)
        XCTAssertNotNil(snapshot.bookAudioCoverageLabel)
    }
}
