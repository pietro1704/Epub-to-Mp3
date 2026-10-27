#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

final class FullPlayerDismissInteractionTests: XCTestCase {
    @MainActor
    func testVisibleTransportControlsKeepTheirTouchesInTheHostCoordinateSpace() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        let container = UIView(frame: CGRect(x: 20, y: 100, width: 280, height: 200))
        let control = UIButton(frame: CGRect(x: 10, y: 20, width: 80, height: 44))
        host.addSubview(container)
        container.addSubview(control)
        var dismissals = 0
        let interaction = FullPlayerDismissInteraction(view: host, controls: { [control] },
            onBegin: { true }, onCancel: {}, onDismiss: { dismissals += 1 })
        interaction.install()
        XCTAssertFalse(interaction.acceptsTouch(at: CGPoint(x: 40, y: 130)))
        XCTAssertTrue(interaction.acceptsTouch(at: CGPoint(x: 200, y: 400)))
        control.isHidden = true
        XCTAssertTrue(interaction.acceptsTouch(at: CGPoint(x: 40, y: 130)))
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(host.gestureRecognizers?.count, 1)
        XCTAssertFalse(host.gestureRecognizers!.first!.cancelsTouchesInView)
    }

    @MainActor
    func testCommittedGestureLeavesItsTransformForThePresentationOwner() {
        let view = UIView()
        var dismissals = 0
        let interaction = FullPlayerDismissInteraction(view: view, controls: { [] },
            onBegin: { true }, onCancel: { XCTFail("An ended long drag should dismiss") },
            onDismiss: { dismissals += 1 })
        interaction.beginDrag()
        view.transform = CGAffineTransform(translationX: 0, y: 160)
        interaction.finishDrag(translation: 160, velocity: 0, cancelled: false)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(view.transform.ty, 160, "Do not flash at identity before the host hides")
        interaction.finishDrag(translation: 160, velocity: 0, cancelled: false)
        XCTAssertEqual(dismissals, 1)
    }

    @MainActor
    func testCancelledLongGestureRestoresWithoutDismissing() {
        let view = UIView()
        var restorations = 0
        let interaction = FullPlayerDismissInteraction(view: view, controls: { [] },
            onBegin: { true }, onCancel: { restorations += 1 },
            onDismiss: { XCTFail("Cancellation cannot commit dismissal") })
        interaction.beginDrag()
        interaction.finishDrag(translation: 300, velocity: 1500, cancelled: true)
        XCTAssertEqual(restorations, 1)
    }

    @MainActor
    func testRejectedInteractionCannotMoveOrDismissThePlayer() {
        let view = UIView()
        let interaction = FullPlayerDismissInteraction(view: view, controls: { [] },
            onBegin: { false }, onCancel: { XCTFail("No interaction was granted") },
            onDismiss: { XCTFail("No interaction was granted") })
        interaction.beginDrag()
        interaction.updateDrag(translation: 200)
        interaction.finishDrag(translation: 200, velocity: 1000, cancelled: false)
        XCTAssertEqual(view.transform, .identity)
    }
}
#endif
