import XCTest
@testable import EpubToMp3

/// Pure-value-type tests for `SegmentBacklog`. Verifies lossless ordering
/// and empty-streak behavior in isolation (no AVPlayer mock needed).
final class SegmentBacklogTests: XCTestCase {

    private func url(_ idx: Int) -> URL {
        URL(fileURLWithPath: "/tmp/seg-\(idx).mp3")
    }

    // MARK: append + drainNext

    func testAppendThenDrainReturnsEntriesInOrder() {
        var backlog = SegmentBacklog()
        XCTAssertTrue(backlog.append(url: url(0), chapterIndex: 0, segmentIndex: 0))
        XCTAssertTrue(backlog.append(url: url(1), chapterIndex: 0, segmentIndex: 1))
        XCTAssertEqual(backlog.count, 2)

        XCTAssertEqual(backlog.drainNext()?.segmentIndex, 0)
        XCTAssertEqual(backlog.drainNext()?.segmentIndex, 1)
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertNil(backlog.drainNext(), "Drain on empty must return nil")
    }

    func testPeekDoesNotRemovePendingSegment() {
        var backlog = SegmentBacklog()
        _ = backlog.append(url: url(7), chapterIndex: 2, segmentIndex: 7)

        XCTAssertEqual(backlog.peekNext()?.segmentIndex, 7)
        XCTAssertEqual(backlog.count, 1,
            "Inspecting a segment before AVQueuePlayer accepts it must not drop it")
        XCTAssertEqual(backlog.drainNext()?.segmentIndex, 7)
    }

    func testBacklogRetainsEveryEntryPastAdvisoryHighWaterMark() {
        var backlog = SegmentBacklog()
        let total = SegmentBacklog.advisoryHighWaterMark + 1
        for i in 0..<total {
            XCTAssertTrue(backlog.append(url: url(i), chapterIndex: 0, segmentIndex: i))
        }
        XCTAssertEqual(backlog.count, total,
            "Deferred audio must never be discarded when playback falls behind conversion")
        XCTAssertTrue(backlog.exceedsAdvisoryHighWaterMark)
        XCTAssertEqual(backlog.highWaterMark, total)
        XCTAssertEqual(backlog.drainNext()?.segmentIndex, 0,
            "The oldest speech remains available after the advisory threshold")
    }

    func testBacklogSortsOutOfOrderArrivalsByProducerIdentity() {
        var backlog = SegmentBacklog()
        XCTAssertTrue(backlog.append(url: url(20), chapterIndex: 2, segmentIndex: 0))
        XCTAssertTrue(backlog.append(url: url(1), chapterIndex: 1, segmentIndex: 1))
        XCTAssertTrue(backlog.append(url: url(0), chapterIndex: 1, segmentIndex: 0))

        XCTAssertEqual(
            [backlog.drainNext(), backlog.drainNext(), backlog.drainNext()]
                .compactMap { $0 }
                .map(\.identity),
            [
                .init(chapterIndex: 1, segmentIndex: 0),
                .init(chapterIndex: 1, segmentIndex: 1),
                .init(chapterIndex: 2, segmentIndex: 0),
            ]
        )
    }

    func testDuplicateIdentityIsRejectedWithoutReplacingOriginalFile() {
        var backlog = SegmentBacklog()
        XCTAssertTrue(backlog.append(url: url(0), chapterIndex: 0, segmentIndex: 0))
        XCTAssertFalse(backlog.append(url: url(99), chapterIndex: 0, segmentIndex: 0))

        XCTAssertEqual(backlog.count, 1)
        XCTAssertEqual(backlog.drainNext()?.url, url(0))
    }

    // MARK: empty-streak detector

    func testRecordEmptyEscalatesAfterThreshold() {
        var backlog = SegmentBacklog()
        for _ in 0..<(SegmentBacklog.emptyStreakErrorThreshold - 1) {
            XCTAssertFalse(backlog.recordEmpty(),
                "Below the threshold, no escalation")
        }
        XCTAssertTrue(backlog.recordEmpty(),
            "At the threshold, recordEmpty signals escalation")
        XCTAssertEqual(backlog.emptyStreak, SegmentBacklog.emptyStreakErrorThreshold)
    }

    func testResetEmptyStreakClearsCounter() {
        var backlog = SegmentBacklog()
        for _ in 0..<3 { _ = backlog.recordEmpty() }
        XCTAssertEqual(backlog.emptyStreak, 3)
        backlog.resetEmptyStreak()
        XCTAssertEqual(backlog.emptyStreak, 0)
        // After reset, the streak builds from scratch — does not
        // escalate on the next non-threshold-crossing call.
        XCTAssertFalse(backlog.recordEmpty())
    }

    // MARK: clear

    func testClearReturnsAllURLsAndResetsStreak() {
        var backlog = SegmentBacklog()
        _ = backlog.append(url: url(0), chapterIndex: 0, segmentIndex: 0)
        _ = backlog.append(url: url(1), chapterIndex: 0, segmentIndex: 1)
        _ = backlog.recordEmpty()
        XCTAssertEqual(backlog.count, 2)
        XCTAssertEqual(backlog.emptyStreak, 1)

        let cleared = backlog.clear()
        XCTAssertEqual(Set(cleared), Set([url(0), url(1)]))
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertEqual(backlog.emptyStreak, 0)
    }

    func testDrainPreservesSentenceID() {
        var backlog = SegmentBacklog()
        _ = backlog.append(
            url: url(3),
            chapterIndex: 1,
            segmentIndex: 3,
            sentenceId: "chapter-1-sentence-3"
        )

        XCTAssertEqual(backlog.drainNext()?.sentenceId, "chapter-1-sentence-3")
    }
}
