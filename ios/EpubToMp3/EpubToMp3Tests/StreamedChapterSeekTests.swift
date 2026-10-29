import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class StreamedChapterSeekTests: XCTestCase {
    func testChapterRelativePositionAcrossUnevenSegmentsAndConfirmedEnd() {
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 75, durations: [20, 20, 20, 20, 20]),
            .ready(.init(segmentIndex: 3, offset: 15, chapterBase: 60)))
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 100, durations: [20, 20, 20, 20, 20], allowsFinalEndpoint: true),
            .ready(.init(segmentIndex: 4, offset: 20, chapterBase: 80)))
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 17, durations: [3, 12, 8]),
            .ready(.init(segmentIndex: 2, offset: 2, chapterBase: 15)))
    }

    func testSelectedTimeWaitsForContainingChunkThenKeepsItsOffset() {
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 35, durations: [15]), .waiting)
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 35, durations: [15, 15]), .waiting)
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 35, durations: [15, 15, 15]),
            .ready(.init(segmentIndex: 2, offset: 5, chapterBase: 30)))
    }

    func testExactBoundaryBelongsToFollowingChunkUntilChapterEndIsConfirmed() {
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 15, durations: [15]), .waiting)
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 15, durations: [15, 15]),
            .ready(.init(segmentIndex: 1, offset: 0, chapterBase: 15)))
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 15, durations: [15], allowsFinalEndpoint: true),
            .ready(.init(segmentIndex: 0, offset: 15, chapterBase: 0)))
    }

    func testSuffixOriginIsAddedExactlyOnce() {
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 335, startingPosition: 300, durations: [15, 15, 15]),
            .ready(.init(segmentIndex: 2, offset: 5, chapterBase: 330)))
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 300, startingPosition: 300, durations: [15]),
            .ready(.init(segmentIndex: 0, offset: 0, chapterBase: 300)))
        XCTAssertNil(StreamedChapterSeek.resolve(position: 35, startingPosition: 300, durations: [15]))
    }

    func testMissingAudioNeverClampsTheSelectedTime() {
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 155, durations: []), .waiting)
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 155, durations: Array(repeating: 15, count: 7)), .waiting)
        XCTAssertEqual(StreamedChapterSeek.resolve(position: 155, durations: Array(repeating: 15, count: 11)),
            .ready(.init(segmentIndex: 10, offset: 5, chapterBase: 150)))
    }

    func testInvalidMeasurementsCannotSelectAnAudibleChunk() {
        for invalid in [Double.nan, .infinity, -1] {
            XCTAssertNil(StreamedChapterSeek.resolve(position: invalid, durations: [15]))
            XCTAssertNil(StreamedChapterSeek.resolve(position: 5, startingPosition: invalid, durations: [15]))
            XCTAssertNil(StreamedChapterSeek.resolve(position: 5, durations: [invalid]))
        }
        XCTAssertNil(StreamedChapterSeek.resolve(position: 5, durations: [0]))
    }
}
