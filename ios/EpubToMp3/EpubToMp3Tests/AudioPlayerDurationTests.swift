import XCTest
@testable import EpubToMp3

final class AudioPlayerDurationTests: XCTestCase {
    func testValidatedDurationAcceptsOnlyPositiveFiniteReadyValues() {
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(Double.nan, isReadyToPlay: false))
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(0, isReadyToPlay: false))
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(Double.nan, isReadyToPlay: true))
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(0, isReadyToPlay: true))
        XCTAssertEqual(AudioPlayer.validatedDurationSeconds(3600, isReadyToPlay: true), 3600)
        XCTAssertEqual(AudioPlayer.validatedDurationSeconds(12.5, isReadyToPlay: true), 12.5)
    }

    func testSegmentModeUsesChapterRelativePositionAcrossTwentySecondSegments() {
        let durations = [20.0, 20.0, 20.0, 20.0, 20.0]

        XCTAssertEqual(AudioPlayer.segmentPosition(durations: durations, segmentIndex: 0, itemPosition: 10), 10)
        XCTAssertEqual(AudioPlayer.segmentPosition(durations: durations, segmentIndex: 2, itemPosition: 10), 50)
        XCTAssertEqual(AudioPlayer.segmentPosition(durations: durations, segmentIndex: 3, itemPosition: 15), 75)
        XCTAssertEqual(AudioPlayer.segmentDuration(durations: durations), 100)
    }

    func testSegmentModeProgressAndRemainingAreFiniteAndClamped() {
        XCTAssertEqual(AudioPlayer.segmentProgress(position: -10, duration: 100), 0)
        XCTAssertEqual(AudioPlayer.segmentProgress(position: 75, duration: 100), 0.75)
        XCTAssertEqual(AudioPlayer.segmentProgress(position: 150, duration: 100), 1)
        XCTAssertEqual(AudioPlayer.segmentRemaining(position: 150, duration: 100), 0)
        XCTAssertEqual(AudioPlayer.segmentRemaining(position: -10, duration: 100), 100)
    }

    func testSegmentModeSeekResolvesTargetAcrossSegments() {
        let target = AudioPlayer.segmentSeekTarget(position: 75, durations: [20, 20, 20, 20, 20])

        XCTAssertEqual(target?.segmentIndex, 3)
        XCTAssertEqual(target?.offset, 15)
        XCTAssertEqual(AudioPlayer.segmentSeekTarget(position: 100, durations: [20, 20, 20, 20, 20])?.segmentIndex, 4)
        XCTAssertEqual(AudioPlayer.segmentSeekTarget(position: 100, durations: [20, 20, 20, 20, 20])?.offset, 20)
    }

    func testSegmentQueueDrainsBacklogBeforeItCanStarve() {
        XCTAssertFalse(AudioPlayer.shouldDrainSegmentBacklog(queueCount: 5, maxQueueAhead: 5))
        XCTAssertTrue(AudioPlayer.shouldDrainSegmentBacklog(queueCount: 4, maxQueueAhead: 5))
        XCTAssertTrue(AudioPlayer.shouldDrainSegmentBacklog(queueCount: 0, maxQueueAhead: 5))
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
