import XCTest
@testable import EpubToMp3

final class AudioPlayerDurationTests: XCTestCase {
    func testValidatedDurationAcceptsOnlyPositiveFiniteReadyValues() {
        XCTAssertNil(PlaybackSegmentSession.validatedDurationSeconds(Double.nan, isReadyToPlay: false))
        XCTAssertNil(PlaybackSegmentSession.validatedDurationSeconds(0, isReadyToPlay: false))
        XCTAssertNil(PlaybackSegmentSession.validatedDurationSeconds(Double.nan, isReadyToPlay: true))
        XCTAssertNil(PlaybackSegmentSession.validatedDurationSeconds(0, isReadyToPlay: true))
        XCTAssertEqual(PlaybackSegmentSession.validatedDurationSeconds(3600, isReadyToPlay: true), 3600)
        XCTAssertEqual(PlaybackSegmentSession.validatedDurationSeconds(12.5, isReadyToPlay: true), 12.5)
    }

    func testSegmentModeUsesChapterRelativePositionAcrossTwentySecondSegments() {
        let durations = [20.0, 20.0, 20.0, 20.0, 20.0]

        XCTAssertEqual(PlaybackSegmentSession.segmentPosition(durations: durations, segmentIndex: 0, itemPosition: 10), 10)
        XCTAssertEqual(PlaybackSegmentSession.segmentPosition(durations: durations, segmentIndex: 2, itemPosition: 10), 50)
        XCTAssertEqual(PlaybackSegmentSession.segmentPosition(durations: durations, segmentIndex: 3, itemPosition: 15), 75)
        XCTAssertEqual(PlaybackSegmentSession.segmentDuration(durations: durations), 100)
    }

    func testSegmentModeProgressAndRemainingAreFiniteAndClamped() {
        XCTAssertEqual(PlaybackSegmentSession.segmentProgress(position: -10, duration: 100), 0)
        XCTAssertEqual(PlaybackSegmentSession.segmentProgress(position: 75, duration: 100), 0.75)
        XCTAssertEqual(PlaybackSegmentSession.segmentProgress(position: 150, duration: 100), 1)
        XCTAssertEqual(PlaybackSegmentSession.segmentRemaining(position: 150, duration: 100), 0)
        XCTAssertEqual(PlaybackSegmentSession.segmentRemaining(position: -10, duration: 100), 100)
    }

    func testSegmentQueueDrainsBacklogBeforeItCanStarve() {
        XCTAssertFalse(PlaybackSegmentSession.shouldDrainSegmentBacklog(queueCount: 5, maxQueueAhead: 5))
        XCTAssertTrue(PlaybackSegmentSession.shouldDrainSegmentBacklog(queueCount: 4, maxQueueAhead: 5))
        XCTAssertTrue(PlaybackSegmentSession.shouldDrainSegmentBacklog(queueCount: 0, maxQueueAhead: 5))
    }

    @MainActor
    func testBufferedChapterDoesNotResetActiveChapterEstimate() {
        let player = AudioPlayer()
        player.enqueueSegment(data: Data([0xFF, 0xFB, 0x90, 0x00]), chapterIndex: 0, segmentIndex: 0)
        player.setSegmentChapterEstimate(123, forChapterIndex: 0)

        player.enqueueSegment(data: Data([0xFF, 0xFB, 0x90, 0x00]), chapterIndex: 1, segmentIndex: 0)

        XCTAssertEqual(player.currentChapterIndex, 0)
        XCTAssertEqual(player.durationSeconds, 123,
            "Buffered chapter metadata must not reset the duration of audible audio")
    }
}
