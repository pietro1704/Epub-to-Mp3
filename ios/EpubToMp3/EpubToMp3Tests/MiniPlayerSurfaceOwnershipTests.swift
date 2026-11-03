#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class MiniPlayerSurfaceOwnershipTests: XCTestCase {
    private func materials(in view: UIView) -> [UIVisualEffectView] {
        view.subviews.compactMap { $0 as? UIVisualEffectView }
            .filter { !$0.isHidden && $0.alpha > 0 && $0.effect != nil }
    }

    func testSystemAccessoryDoesNotDrawAnAppOwnedCapsuleInEitherAppearance() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let mini = MiniPlayerBarUIKitView(usesSystemManagedBottomInset: true)
            mini.overrideUserInterfaceStyle = style
            XCTAssertTrue(materials(in: mini).isEmpty,
                "The tab accessory already supplies the one material surface")
            XCTAssertEqual(mini.backgroundColor, UIColor.clear)
        }
    }

    func testFloatingPlayerRetainsExactlyOneMaterialInEitherAppearance() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let mini = MiniPlayerBarUIKitView()
            mini.overrideUserInterfaceStyle = style
            XCTAssertEqual(materials(in: mini).count, 1)
        }
    }

    func testRemovingAccessoryMaterialPreservesLayoutAndControlTouchAreas() throws {
        let mini = MiniPlayerBarUIKitView(usesSystemManagedBottomInset: true)
        mini.frame = CGRect(x: 0, y: 0, width: 390, height: 60)
        mini.layoutIfNeeded()
        let pill = try XCTUnwrap(mini.subviews.first {
            $0.accessibilityIdentifier == "miniPlayer.pillMaterial"
        })
        XCTAssertTrue(pill.isHidden)
        XCTAssertEqual(pill.bounds.height, 60, accuracy: 0.5)
        for identifier in ["miniPlayer.playPause", "miniPlayer.previous", "miniPlayer.next", "miniPlayer.rate"] {
            let control = try XCTUnwrap(find(identifier, in: mini))
            XCTAssertGreaterThanOrEqual(control.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(control.bounds.height, 44)
            XCTAssertFalse(control.isHidden)
        }
    }

    func testConversionClearanceIsRemovedWithPlayerAndPreservesOtherInsets() {
        let controller = UITableViewController(style: .insetGrouped)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.additionalSafeAreaInsets.bottom = 12
        let clearance = MiniPlayerScrollClearance()
        let originalBottom = controller.view.bounds.maxY - controller.view.safeAreaInsets.bottom
        let player = CGRect(x: 0, y: originalBottom - 60, width: 390, height: 60)
        clearance.update(controller, occlusion: player)
        XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 72, accuracy: 0.5)
        clearance.update(controller, occlusion: nil)
        XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 12, accuracy: 0.5)
        clearance.update(controller, occlusion: CGRect(x: 600, y: 784, width: 100, height: 60))
        XCTAssertEqual(controller.additionalSafeAreaInsets.bottom, 12, accuracy: 0.5)
    }

    private func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        return view.subviews.lazy.compactMap { self.find(identifier, in: $0) }.first
    }
}
#endif
