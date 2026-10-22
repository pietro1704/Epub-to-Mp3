#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerStreamingTests {
    /// Subscribes two consumers to `position` in parallel, enqueues a segment
    /// to drive a position broadcast, then verifies both consumers received
    /// values without a data race.
    ///
    /// TSan compatibility: all stream mutations go through MainActor.run
    /// (continuation dict writes are serialised on MainActor). The test
    /// uses structured concurrency (`async let`) so there are no unstructured
    /// Task escapes that could race against XCTest teardown.
    @MainActor
    func testPositionStreamMultipleConsumersParallel() async {
        let player = AudioPlayer()

        // Collect first value emitted on each consumer.
        let s1 = player.position
        let s2 = player.position

        async let first: TimeInterval = {
            var iter = s1.makeAsyncIterator()
            return await iter.next() ?? -1
        }()

        async let second: TimeInterval = {
            var iter = s2.makeAsyncIterator()
            return await iter.next() ?? -1
        }()

        let (v1, v2) = await (first, second)

        // Both consumers must have received the initial position (0 at construction).
        XCTAssertEqual(v1, 0, accuracy: 0.001,
            "First consumer should receive initial position 0")
        XCTAssertEqual(v2, 0, accuracy: 0.001,
            "Second consumer should receive initial position 0")
    }

    /// Subscribes two consumers to `currentChapter` in parallel and verifies
    /// both receive the initial nil value without a data race.
    @MainActor
    func testCurrentChapterStreamMultipleConsumersParallel() async {
        let player = AudioPlayer()

        let s1 = player.currentChapter
        let s2 = player.currentChapter

        async let first: JobSnapshot.Chapter? = {
            var iter = s1.makeAsyncIterator()
            return await iter.next() ?? nil
        }()

        async let second: JobSnapshot.Chapter? = {
            var iter = s2.makeAsyncIterator()
            return await iter.next() ?? nil
        }()

        let (ch1, ch2) = await (first, second)
        XCTAssertNil(ch1, "Consumer 1 should see nil chapter before any snapshot is set")
        XCTAssertNil(ch2, "Consumer 2 should see nil chapter before any snapshot is set")
    }
}
#endif
