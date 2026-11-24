#if canImport(AVFoundation) && canImport(MediaPlayer)
import Foundation
import XCTest
@testable import EpubToMp3

/// STREAM-SEEK-PRIORITY: the listener's destination is the top priority of the streaming job, and the chunks of a
/// chapter the core preempted are dropped (CONTEXT.md, "Streaming seek priority").
@MainActor
final class StreamingSeekPriorityTests: XCTestCase {
    private final class Calls {
        var prioritized: [Int] = []
        var windows: [(chapter: Int, ahead: Int)] = []
    }

    /// C function pointers cannot capture: what the fake core answers lives in statics, reset for every test.
    private nonisolated(unsafe) static var preemptedChapters: Set<Int> = []
    private nonisolated(unsafe) static var windowContainsEverything = true

    override func setUp() {
        super.setUp()
        Self.preemptedChapters = []
        Self.windowContainsEverything = true
    }

    private func makeControl(_ calls: Calls = Calls(), withPreemptedSymbol: Bool = true) -> ConverterPlaybackControl {
        let box = Unmanaged.passRetained(calls)
        addTeardownBlock { box.release() }
        return ConverterPlaybackControl(
            rawHandle: box.toOpaque(), free: { _ in }, cancel: { _ in },
            prioritize: { raw, chapter in
                Unmanaged<Calls>.fromOpaque(UnsafeMutableRawPointer(mutating: raw!)).takeUnretainedValue().prioritized.append(chapter)
                return true
            },
            setWindow: { raw, chapter, ahead in
                Unmanaged<Calls>.fromOpaque(UnsafeMutableRawPointer(mutating: raw!)).takeUnretainedValue().windows.append((chapter, ahead))
            },
            windowContains: { _, _ in StreamingSeekPriorityTests.windowContainsEverything },
            chapterIsPreempted: withPreemptedSymbol ? { _, chapter in StreamingSeekPriorityTests.preemptedChapters.contains(chapter) } : nil)
    }

    func testChunksOfAPreemptedChapterAreDroppedEvenInsideThePlaybackWindow() {
        Self.preemptedChapters = [3]
        let control = makeControl()
        XCTAssertFalse(control.acceptsChunks(forChapter: 3), "Chapter 3 yields to the listener's destination")
        XCTAssertTrue(control.acceptsChunks(forChapter: 4))
        XCTAssertTrue(control.contains(chapterIndex: 3), "The old window check would have kept delivering chapter 3")
    }

    func testChunksOutsideTheWindowAreNoLongerTheDecisionOfTheWindowCheck() {
        // The core only synthesizes what the window and the priority allow; the preempted check is the one that drops.
        Self.windowContainsEverything = false
        let control = makeControl()
        XCTAssertTrue(control.acceptsChunks(forChapter: 9))
    }

    func testAnOlderLibraryWithoutThePreemptedSymbolNeverPreempts() {
        let control = makeControl(withPreemptedSymbol: false)
        XCTAssertFalse(control.isPreempted(chapterIndex: 2))
        XCTAssertTrue(control.acceptsChunks(forChapter: 2))
    }

    func testACancelledJobAcceptsNothing() {
        let control = makeControl()
        control.cancel()
        XCTAssertFalse(control.acceptsChunks(forChapter: 1))
    }

    func testANavigationMovesTheWindowAndPrioritizesTheDestination() {
        let calls = Calls()
        let control = makeControl(calls)
        let navigation = AudioPlayer.PendingNavigation(requestID: UUID(), jobID: "job", chapterIndex: 5)
        XCTAssertTrue(StreamingSeekPriority.apply(navigation, to: control))
        XCTAssertEqual(calls.prioritized, [5], "The chapter the listener went to is synthesized first")
        XCTAssertEqual(calls.windows.map(\.chapter), [5])
        XCTAssertEqual(calls.windows.map(\.ahead), [1])
    }

    func testAChapterRequestWithoutAListeningSeekStillPrioritizes() {
        // Next / previous and a contents pick are chapter requests: chapter-time 0, no reader page, no approximate time.
        let calls = Calls()
        let control = makeControl(calls)
        for chapter in [2, 7] {
            let navigation = AudioPlayer.PendingNavigation(requestID: UUID(), jobID: "job", chapterIndex: chapter,
                                                           target: .chapterTime(0))
            XCTAssertTrue(StreamingSeekPriority.apply(navigation, to: control))
        }
        XCTAssertEqual(calls.prioritized, [2, 7])
    }

    func testAStoppedJobIgnoresTheNavigation() {
        let calls = Calls()
        let control = makeControl(calls)
        control.cancel()
        let navigation = AudioPlayer.PendingNavigation(requestID: UUID(), jobID: "job", chapterIndex: 4)
        XCTAssertFalse(StreamingSeekPriority.apply(navigation, to: control))
        XCTAssertTrue(calls.prioritized.isEmpty)
    }
}
#endif
