import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ReaderBookSearchTests: XCTestCase {
    func testSearchBeginsAtCurrentChapterAndWrapsOnceInSourceOrder() {
        let chapters = [3, 40, 90].map { ReaderBookSearch.Chapter(position: $0, text: "Matching passage") }
        XCTAssertEqual(ReaderBookSearch.candidates(query: "passage", chapters: chapters, startingAt: 40), [40, 90, 3])
    }

    func testMissingCurrentChapterFallsBackWithoutInventingAnIndex() {
        let chapters = [ReaderBookSearch.Chapter(position: 12, text: "Target")]
        XCTAssertEqual(ReaderBookSearch.candidates(query: "target", chapters: chapters, startingAt: -1), [12])
    }

    func testEmptyOrMissingQueryHasNoMatches() {
        XCTAssertNil(ReaderBookSearch.firstRange(query: " \n ", in: "Text"))
        XCTAssertNil(ReaderBookSearch.firstRange(query: "missing", in: "Text"))
        XCTAssertEqual(ReaderBookSearch.candidates(query: "anything", chapters: [], startingAt: 0), [])
    }

    func testPortugueseCaseAndDiacriticsAreSearchable() {
        XCTAssertEqual(ReaderBookSearch.firstRange(query: "CAFE", in: "Um café."), NSRange(location: 3, length: 4))
    }

    func testReturnedRangeUsesDisplayedUTF16Coordinates() throws {
        let range = try XCTUnwrap(ReaderBookSearch.firstRange(query: "target", in: "📖 Heading\nTarget"))
        XCTAssertEqual(range, NSRange(location: 11, length: 6))
        XCTAssertNotEqual(range, ReaderBookSearch.firstRange(query: "target", in: "Target"),
            "A raw-source offset cannot select the same words after rendered text shifts")
    }

    func testQueryCharactersAreLiteralRatherThanRegexSyntax() {
        XCTAssertEqual(ReaderBookSearch.firstRange(query: "[x]+", in: "Find [x]+ here"), NSRange(location: 5, length: 4))
    }

    func testCancelledScanDoesNotPublishPartialCandidates() {
        let chapters = [0, 1, 2].map { ReaderBookSearch.Chapter(position: $0, text: "Target") }
        var checks = 0
        let result = ReaderBookSearch.candidates(query: "target", chapters: chapters, startingAt: 0) {
            checks += 1
            return checks > 1
        }
        XCTAssertTrue(result.isEmpty)
    }

    func testRenderedFirstMatchIsChosenFromActualVisibleText() {
        let rendered = "Visible text. Another visible text."
        XCTAssertEqual(ReaderBookSearch.firstRange(query: "visible", in: rendered), NSRange(location: 0, length: 7))
    }
}
