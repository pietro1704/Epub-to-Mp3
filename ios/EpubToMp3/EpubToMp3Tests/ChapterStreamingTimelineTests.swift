import AVFoundation
import XCTest
@testable import EpubToMp3

@MainActor
final class ChapterStreamingTimelineTests: XCTestCase {
    func testBufferedDurationCannotReplaceTheFullChapterEstimate() {
        let segments = PlaybackSegmentSession()
        segments.estimate(600, chapter: 0)
        _ = segments.activate(.init(chapterIndex: 0, segmentIndex: 0))
        segments.setBase(12)
        let queue = AVQueuePlayer()
        XCTAssertEqual(segments.observeDuration(queue: queue, snapshot: nil), 600)
    }

    func testUnknownTotalDoesNotBecomeElapsedOrBufferedTime() {
        let segments = PlaybackSegmentSession()
        _ = segments.activate(.init(chapterIndex: 0, segmentIndex: 0))
        segments.setBase(12)
        XCTAssertEqual(segments.observeDuration(queue: AVQueuePlayer(), snapshot: nil), 0)
    }

    func testChangingChapterSelectsItsOwnEstimateAndResetsPosition() {
        let segments = PlaybackSegmentSession()
        segments.estimate(600, chapter: 0)
        segments.estimate(180, chapter: 1)
        _ = segments.activate(.init(chapterIndex: 0, segmentIndex: 0))
        segments.setBase(100)
        _ = segments.activate(.init(chapterIndex: 1, segmentIndex: 0))
        XCTAssertEqual(segments.chapterDuration, 180)
        XCTAssertEqual(segments.cumulativeBase, 0)
    }

    func testStartingFromAPageRetainsTheChapterCoordinate() {
        let segments = PlaybackSegmentSession()
        segments.estimate(600, chapter: 4, startingRatio: 0.5)
        _ = segments.activate(.init(chapterIndex: 4, segmentIndex: 0))
        XCTAssertEqual(segments.cumulativeBase, 300)
        XCTAssertEqual(segments.chapterDuration, 600)
        segments.advanceBase(10)
        XCTAssertEqual(segments.cumulativeBase, 310)
    }

    func testBookResetDropsAllPreviousEstimatesAndStartingOffsets() {
        let segments = PlaybackSegmentSession()
        segments.estimate(600, chapter: 0, startingRatio: 0.5)
        segments.resetMetadata()
        _ = segments.activate(.init(chapterIndex: 0, segmentIndex: 0))
        XCTAssertEqual(segments.chapterDuration, 0)
        XCTAssertEqual(segments.cumulativeBase, 0)
        XCTAssertTrue(segments.estimatedDurations.isEmpty)
    }

    func testCompletedSnapshotUsesExplicitChapterAxisAndMayRefineDownward() throws {
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
        {"jobId":"job","state":"running","chapterIndexBase":0,"chapterProgress":[
          {"index":2,"status":"completed","durationSeconds":900},
          {"index":1,"status":"completed","durationSeconds":420}
        ]}
        """.utf8))
        let segments = PlaybackSegmentSession()
        segments.estimate(600, chapter: 1)
        _ = segments.activate(.init(chapterIndex: 1, segmentIndex: 0))
        XCTAssertEqual(segments.observeDuration(queue: AVQueuePlayer(), snapshot: snapshot), 420)
    }

    func testPageSuffixDurationIsNeverTreatedAsTheWholeChapter() throws {
        let snapshot = try JSONDecoder().decode(JobSnapshot.self, from: Data("""
        {"jobId":"job","state":"finished","chapterIndexBase":0,"chapterProgress":[
          {"index":1,"status":"completed","durationSeconds":200}
        ]}
        """.utf8))
        let segments = PlaybackSegmentSession()
        segments.estimate(600, chapter: 1, startingRatio: 0.5)
        _ = segments.activate(.init(chapterIndex: 1, segmentIndex: 0))
        XCTAssertNil(segments.confirmedEnd(for: 1, snapshot: snapshot))
        XCTAssertEqual(segments.observeDuration(queue: AVQueuePlayer(), snapshot: snapshot), 600)
    }
}
