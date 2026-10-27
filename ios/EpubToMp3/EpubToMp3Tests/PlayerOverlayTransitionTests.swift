#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class PlayerOverlayTransitionTests: XCTestCase {
    func testShowHideAndReopenResetTransformOnlyWhileHidden() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let transition = PlayerOverlayTransition(view: view, style: .sheet)
        transition.setVisible(true, animated: false)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.alpha, 1)
        XCTAssertTrue(view.accessibilityViewIsModal)
        view.transform = CGAffineTransform(translationX: 0, y: 160)
        transition.setVisible(false, animated: false)
        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(view.accessibilityViewIsModal)
        XCTAssertEqual(view.transform, .identity)
        transition.setVisible(true, animated: false)
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.transform, .identity)
    }

    func testRepeatedPlaybackRefreshCannotResetAnInteractiveDrag() {
        let view = UIView()
        let transition = PlayerOverlayTransition(view: view, style: .sheet)
        transition.setVisible(true, animated: false)
        XCTAssertTrue(transition.beginInteraction())
        view.transform = CGAffineTransform(translationX: 0, y: 75)
        transition.setVisible(true, animated: false)
        XCTAssertEqual(view.transform.ty, 75)
        transition.restoreAfterInteraction()
        XCTAssertEqual(view.transform, .identity)
        XCTAssertFalse(view.isHidden)
    }

    func testLateGestureCancellationCannotReopenAProgrammaticallyHiddenPlayer() {
        let view = UIView()
        let transition = PlayerOverlayTransition(view: view, style: .sheet)
        transition.setVisible(true, animated: false)
        XCTAssertTrue(transition.beginInteraction())
        transition.setVisible(false, animated: false)
        transition.restoreAfterInteraction()
        XCTAssertTrue(view.isHidden)
        XCTAssertFalse(transition.beginInteraction())
    }

    func testImmediateMiniPlayerHideSurvivesRepeatedVisibilityRefreshes() {
        let view = UIView()
        let transition = IOSMiniPlayerPresentation(view: view)
        transition.setVisible(visible: true, animated: false)
        transition.hideImmediately()
        transition.setVisible(visible: false, animated: false)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.alpha, 0)
        transition.setVisible(visible: true, animated: false)
        XCTAssertFalse(view.isHidden)
    }
}
#endif
