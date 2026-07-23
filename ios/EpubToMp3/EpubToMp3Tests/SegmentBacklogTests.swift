import XCTest
@testable import EpubToMp3

/// Pure-value-type tests for `SegmentBacklog`. Verifies the eviction
/// + empty-streak policy in isolation (no AVPlayer mock needed).
final class SegmentBacklogTests: XCTestCase {

    private func url(_ idx: Int) -> URL {
        URL(fileURLWithPath: "/tmp/seg-\(idx).mp3")
    }

    // MARK: append + drainNext

    func testAppendThenDrainReturnsEntriesInOrder() {
        var backlog = SegmentBacklog()
        XCTAssertNil(backlog.append(url: url(0), chapterIndex: 0, segmentIndex: 0))
        XCTAssertNil(backlog.append(url: url(1), chapterIndex: 0, segmentIndex: 1))
        XCTAssertEqual(backlog.count, 2)

        XCTAssertEqual(backlog.drainNext()?.segmentIndex, 0)
        XCTAssertEqual(backlog.drainNext()?.segmentIndex, 1)
        XCTAssertTrue(backlog.isEmpty)
        XCTAssertNil(backlog.drainNext(), "Drain on empty must return nil")
    }

    func testCapacityCapsBacklogAndEvictsOldest() {
        var backlog = SegmentBacklog()
        for i in 0..<SegmentBacklog.capacity {
            XCTAssertNil(backlog.append(url: url(i), chapterIndex: 0, segmentIndex: i),
                "No eviction until the cap is reached")
        }
        // One more — must evict the oldest (seg 0).
        let evicted = backlog.append(url: url(99), chapterIndex: 1, segmentIndex: 99)
        XCTAssertEqual(evicted, url(0))
        XCTAssertEqual(backlog.count, SegmentBacklog.capacity)
        // The first remaining entry should now be seg 1 (the original
        // second entry), not seg 0.
        XCTAssertEqual(backlog.drainNext()?.segmentIndex, 1)
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
