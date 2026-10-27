import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ChapterPlaybackTimelineTests: XCTestCase {
    private func chapter(index: Int = 1, words: Int, speech: String? = nil, kind: String? = nil) throws -> EbookFulltext.Chapter {
        var object: [String: Any] = ["index": index, "text": Array(repeating: "palavra", count: words).joined(separator: " ")]
        object["speechText"] = speech
        object["contentKind"] = kind
        return try JSONDecoder().decode(EbookFulltext.Chapter.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    func testEstimateUsesEntireChapterAndCanonicalSourceIndex() throws {
        let chapters = try [chapter(index: 1, words: 200), chapter(index: 4, words: 400)]
        XCTAssertEqual(ChapterPlaybackTimeline.estimates(for: chapters), [0: 60, 3: 120])
    }

    func testSpeechPayloadIsUsedWhenItDiffersFromReaderText() throws {
        let value = try chapter(words: 200, speech: "nota de rodapé")
        XCTAssertEqual(ChapterPlaybackTimeline.estimate(for: value), 0.9, accuracy: 0.001)
    }

    func testEmptyTextAndImageChaptersHaveNoInventedDuration() throws {
        XCTAssertEqual(ChapterPlaybackTimeline.estimate(for: try chapter(words: 0)), 0)
        XCTAssertEqual(ChapterPlaybackTimeline.estimate(for: try chapter(words: 100, kind: "images")), 0)
    }

    func testIncompleteChapterKeepsItsWholeChapterEstimate() {
        let value = ChapterPlaybackTimeline(estimate: 600, confirmed: nil)
        XCTAssertEqual(value.duration, 600)
        XCTAssertTrue(value.isEstimated)
        XCTAssertEqual(value.remaining(position: 30, rate: 1), 570)
    }

    func testConfirmedDurationMayBeShorterThanTheEstimate() {
        let value = ChapterPlaybackTimeline(estimate: 600, confirmed: 420)
        XCTAssertEqual(value.duration, 420)
        XCTAssertFalse(value.isEstimated)
    }

    func testUnknownTotalIsNotPresentedAsDownloadedFragmentDuration() {
        let value = ChapterPlaybackTimeline(estimate: nil, confirmed: nil)
        XCTAssertEqual(value.duration, 0)
        XCTAssertFalse(value.isEstimated)
    }

    func testInvalidDurationsNeverReachTheSlider() {
        for invalid in [Double.nan, .infinity, -1, 0] {
            XCTAssertEqual(ChapterPlaybackTimeline(estimate: invalid, confirmed: invalid).duration, 0)
            XCTAssertEqual(ChapterPlaybackTimeline(estimate: 120, confirmed: invalid).duration, 120)
        }
    }

    func testRemainingUsesWallTimeAtTheSelectedPlaybackRate() {
        let value = ChapterPlaybackTimeline(estimate: 600, confirmed: nil)
        XCTAssertEqual(value.remaining(position: 120, rate: 2), 240)
        XCTAssertEqual(value.remaining(position: 120, rate: 0.5), 960)
        XCTAssertEqual(value.remaining(position: 700, rate: 1), 0)
        XCTAssertEqual(value.remaining(position: -20, rate: 1), 600)
        XCTAssertEqual(value.remaining(position: .nan, rate: 1), 0)
        XCTAssertEqual(value.remaining(position: 0, rate: 0), 0)
    }
}
