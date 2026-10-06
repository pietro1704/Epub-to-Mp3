import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderViewportTransitionTests: XCTestCase {
    func testRepeatedTargetIsIdempotentAndCapturesOnce() {
        let transition = ReaderViewportTransition()
        var captureCount = 0

        let first = transition.begin(to: true) { captureCount += 1 }
        let repeated = transition.begin(to: true) { captureCount += 1 }

        XCTAssertEqual(first, repeated)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(transition.targetChromeHidden, true)
    }

    func testReplacementMakesPreviousCommitStaleWithoutRecapturing() {
        let transition = ReaderViewportTransition()
        var captureCount = 0
        var events: [String] = []

        let hidden = transition.begin(to: true) { captureCount += 1 }
        let shown = transition.begin(to: false) { captureCount += 1 }

        XCTAssertFalse(transition.commit(hidden, applyFinalGeometry: {
            events.append("stale-layout")
        }, restoreViewport: {
            events.append("stale-restore")
        }))
        XCTAssertTrue(transition.commit(shown, applyFinalGeometry: {
            events.append("final-layout")
        }, restoreViewport: {
            events.append("raw-offset-restore")
        }))
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(events, ["final-layout", "raw-offset-restore"])
        XCTAssertFalse(transition.isActive)
    }

    func testReentrantGeometryChangeInvalidatesItsOwnCommit() {
        let transition = ReaderViewportTransition()
        var captureCount = 0
        let first = transition.begin(to: true) { captureCount += 1 }

        XCTAssertFalse(transition.commit(first, applyFinalGeometry: {
            _ = transition.begin(to: false) { captureCount += 1 }
        }, restoreViewport: {
            XCTFail("A stale transition must not restore a viewport")
        }))
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(transition.targetChromeHidden, false)
    }

    func testCancelInvalidatesOutstandingToken() {
        let transition = ReaderViewportTransition()
        let token = transition.begin(to: true) {}
        transition.cancel()

        XCTAssertFalse(transition.commit(token, applyFinalGeometry: {}, restoreViewport: {}))
        XCTAssertFalse(transition.isActive)
        XCTAssertNil(transition.targetChromeHidden)
    }
}
