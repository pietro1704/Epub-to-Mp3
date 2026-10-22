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
        let interaction = FullPlayerDismissInteraction(view: host, controls: { [control] }, onDismiss: { dismissals += 1 })
        interaction.install()
        XCTAssertFalse(interaction.acceptsTouch(at: CGPoint(x: 40, y: 130)))
        XCTAssertTrue(interaction.acceptsTouch(at: CGPoint(x: 200, y: 400)))
        control.isHidden = true
        XCTAssertTrue(interaction.acceptsTouch(at: CGPoint(x: 40, y: 130)))
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(host.gestureRecognizers?.count, 1)
        XCTAssertFalse(host.gestureRecognizers!.first!.cancelsTouchesInView)
    }
}
#endif
