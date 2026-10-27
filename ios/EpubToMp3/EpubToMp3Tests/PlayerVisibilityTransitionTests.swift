import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class PlayerVisibilityTransitionTests: XCTestCase {
    func testRepeatedHideDoesNotInvalidateItsPendingCompletion() throws {
        var transition = VisibilityTransition()
        let hide = try XCTUnwrap(transition.request(visible: false))
        XCTAssertNil(transition.request(visible: false))
        XCTAssertTrue(transition.isCurrent(hide))
    }

    func testReopeningRejectsTheOldHideCompletion() throws {
        var transition = VisibilityTransition()
        let hide = try XCTUnwrap(transition.request(visible: false))
        let show = try XCTUnwrap(transition.request(visible: true))
        XCTAssertFalse(transition.isCurrent(hide))
        XCTAssertTrue(transition.isCurrent(show))
    }

    func testRapidReversalsLeaveOnlyTheLastRequestCurrent() throws {
        var transition = VisibilityTransition()
        let first = try XCTUnwrap(transition.request(visible: true))
        let second = try XCTUnwrap(transition.request(visible: false))
        let third = try XCTUnwrap(transition.request(visible: true))
        XCTAssertFalse(transition.isCurrent(first))
        XCTAssertFalse(transition.isCurrent(second))
        XCTAssertTrue(transition.isCurrent(third))
    }

    func testImmediateHideInvalidatesAnOpeningAnimation() throws {
        var transition = VisibilityTransition()
        let opening = try XCTUnwrap(transition.request(visible: true))
        transition.invalidate(keeping: false)
        XCTAssertFalse(transition.isCurrent(opening))
        XCTAssertNil(transition.request(visible: false))
        XCTAssertEqual(transition.requestedVisibility, false)
    }

    func testInteractiveRestorationCreatesANewRequestForTheSameVisibleTarget() throws {
        var transition = VisibilityTransition()
        let opening = try XCTUnwrap(transition.request(visible: true))
        transition.invalidate(keeping: true)
        XCTAssertFalse(transition.isCurrent(opening))
        XCTAssertNil(transition.request(visible: true))
        transition.invalidate(keeping: nil)
        let restored = try XCTUnwrap(transition.request(visible: true))
        XCTAssertTrue(transition.isCurrent(restored))
    }
}
