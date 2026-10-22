#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Combine
import Foundation
import XCTest
@testable import EpubToMp3

final class PlaybackQueueObservationTests: XCTestCase {
    @MainActor
    func testCoordinatorForwardsCursorAssignmentsOnceWithWillSetOrdering() {
        let player = AudioPlayer()
        var previous: [Int] = []
        let subscription = player.objectWillChange.sink { previous.append(player.currentChapterIndex) }
        defer { subscription.cancel() }
        player.testHook_setCurrentChapterIndex(5)
        XCTAssertEqual(previous, [0])
        XCTAssertEqual(player.currentChapterIndex, 5)
        player.testHook_setCurrentChapterIndex(5)
        XCTAssertEqual(previous, [0, 5], "Equal assignments preserve the published interface")
    }

    @MainActor
    func testConfirmedSegmentPreservesDurationThenSentenceThenChapterOrdering() {
        let clock = PlaybackClock()
        let session = PlaybackQueueSession(clock: clock)
        let segments = PlaybackSegmentSession()
        let first = SegmentBacklog.Identity(chapterIndex: 2, segmentIndex: 0)
        let next = SegmentBacklog.Identity(chapterIndex: 8, segmentIndex: 0)
        segments.register(URL(fileURLWithPath: "/first.mp3"), identity: first, sentenceID: "first", publication: nil, receipt: nil)
        segments.register(URL(fileURLWithPath: "/next.mp3"), identity: next, sentenceID: "next", publication: nil, receipt: nil)
        segments.estimate(3, chapter: 2)
        segments.estimate(8, chapter: 8)
        session.activateSegment(first, segments: segments)
        var previous: [(Int, String?, TimeInterval)] = []
        let subscription = session.objectWillChange.sink {
            previous.append((session.currentChapterIndex, session.activeSentenceId, clock.durationSeconds))
        }
        defer { subscription.cancel() }
        session.activateSegment(next, segments: segments)
        XCTAssertEqual(previous.count, 3)
        XCTAssertEqual(previous.map { $0.0 }, [2, 2, 8])
        XCTAssertEqual(previous.map { $0.1 }, ["first", nil, nil])
        XCTAssertEqual(previous.map { $0.2 }, [8, 8, 8])
        XCTAssertEqual(session.currentChapterIndex, 8)
        XCTAssertEqual(session.activeSentenceId, "next")
    }

    @MainActor
    func testQueuedItemChangeCannotPublishAfterQueueReplacement() async {
        let session = PlaybackQueueSession()
        let obsoleteQueue = AVQueuePlayer()
        session.mount(obsoleteQueue)
        var changes = 0
        session.observe(time: { _, _ in }, finished: { _ in },
                        itemChanged: { changes += 1 }, duration: { _ in })
        // KVO schedules a MainActor task. Replace the session before that task
        // can run; invalidating observation cannot retract an already queued task.
        obsoleteQueue.insert(AVPlayerItem(url: URL(fileURLWithPath: "/obsolete.wav")), after: nil)
        session.teardown()
        let currentQueue = AVQueuePlayer()
        session.mount(currentQueue)
        defer { session.teardown(); obsoleteQueue.removeAllItems() }
        // A later MainActor task provides an ordered delivery barrier without
        // waiting for AVFoundation to decode or play the test item.
        await Task { @MainActor in }.value
        XCTAssertEqual(changes, 0, "An obsolete queue must not publish into its replacement")
        XCTAssertTrue(session.player === currentQueue)
    }

    @MainActor
    func testQueuedItemChangePublishesForTheMountedQueue() async {
        let session = PlaybackQueueSession()
        let queue = AVQueuePlayer()
        session.mount(queue)
        defer { session.teardown(); queue.removeAllItems() }
        var changes = 0
        session.observe(time: { _, _ in }, finished: { _ in },
                        itemChanged: { changes += 1 }, duration: { _ in })
        queue.insert(AVPlayerItem(url: URL(fileURLWithPath: "/current.wav")), after: nil)
        await Task { @MainActor in }.value
        XCTAssertEqual(changes, 1, "Fencing cannot discard the current queue's KVO delivery")
    }
}
#endif
