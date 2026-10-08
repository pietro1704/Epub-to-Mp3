import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ConversionChapterSelectionTests: XCTestCase {
    func testMalformedNonemptySelectionsNeverBecomeWholeBook() {
        for input in ["invalid", "8-", "-1", "9-8", "8-9-10", "2147483648", "8-bad-9", "8--9", "-2--1",
                      "0-2147483648", "2147483648-1", "-", "+8", "８", "8.0"] {
            XCTAssertThrowsError(try ConversionChapterSelection.parse(input), "Accepted malformed selection: \(input)")
        }
    }

    func testSingleChapterAndInclusiveRangePreserveLiteralIndices() throws {
        let single = try ConversionChapterSelection.parse("8")
        XCTAssertEqual(single.start, 8)
        XCTAssertEqual(single.end, 8)
        let range = try ConversionChapterSelection.parse(" 8 - 9 ")
        XCTAssertEqual(range.start, 8)
        XCTAssertEqual(range.end, 9)
        let repeated = try ConversionChapterSelection.parse("8-8")
        XCTAssertEqual(repeated.start, 8)
        XCTAssertEqual(repeated.end, 8)
        let maximum = try ConversionChapterSelection.parse("2147483647")
        XCTAssertEqual(maximum.start, Int32.max)
        XCTAssertEqual(maximum.end, Int32.max)
    }

    func testOnlyEmptySelectionExplicitlyChoosesWholeBook() throws {
        let whole = try ConversionChapterSelection.parse(" \n\t ")
        XCTAssertEqual(whole.start, -1)
        XCTAssertEqual(whole.end, -1)
        let first = try ConversionChapterSelection.parse("0")
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.end, 0)
    }
}
