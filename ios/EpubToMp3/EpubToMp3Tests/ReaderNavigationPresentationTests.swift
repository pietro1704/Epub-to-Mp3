#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderNavigationPresentationTests: XCTestCase {
    private func apply(_ presentation: ReaderNavigationPresentation, show: Bool, animated: Bool, in view: UIView) {
        presentation.applyLayout(shouldShow: show, animated: animated, commitsLayout: false,
            readerTopToNavigation: nil, readerTopToRoot: nil, in: view)
    }

    func testOpacityTransitionDoesNotCommitTheReadersGeometry() {
        let root = ChromeLayoutTrackingView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let presentation = ReaderNavigationPresentation()
        presentation.install(in: root, target: NSObject(), closeAction: NSSelectorFromString("unusedClose"))
        apply(presentation, show: true, animated: false, in: root)
        let baseline = root.layoutCount
        apply(presentation, show: false, animated: true, in: root)
        XCTAssertEqual(root.layoutCount, baseline,
            "Only the root viewport transaction may force final reader geometry")
    }

    func testNonanimatedRestorationMakesBothChromeSurfacesVisible() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let presentation = ReaderNavigationPresentation()
        presentation.install(in: root, target: NSObject(), closeAction: NSSelectorFromString("unusedClose"))
        apply(presentation, show: false, animated: false, in: root)
        apply(presentation, show: true, animated: false, in: root)
        XCTAssertFalse(presentation.readerNavigationBar.isHidden)
        XCTAssertFalse(presentation.readerNavigationBackground.isHidden)
        XCTAssertEqual(presentation.readerNavigationBar.alpha, 1)
        XCTAssertEqual(presentation.readerNavigationBackground.alpha, 1)
    }

    func testRapidReversalRejectsTheStaleHideCompletion() async throws {
        guard UIView.areAnimationsEnabled,
              !ProcessInfo.processInfo.arguments.contains("-uiTestReduceMotion") else {
            throw XCTSkip("This case requires animated UIKit execution")
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let presentation = ReaderNavigationPresentation()
        presentation.install(in: controller.view, target: controller, closeAction: NSSelectorFromString("unusedClose"))
        controller.view.layoutIfNeeded()
        apply(presentation, show: true, animated: false, in: controller.view)
        await waitForRenderingTurn()
        apply(presentation, show: false, animated: true, in: controller.view)
        await waitForRenderingTurn()
        apply(presentation, show: true, animated: true, in: controller.view)
        let settled = expectation(description: "Both chrome animation completions have run")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        XCTAssertFalse(presentation.readerNavigationBar.isHidden)
        XCTAssertFalse(presentation.readerNavigationBackground.isHidden)
        XCTAssertEqual(presentation.readerNavigationBar.alpha, 1)
    }

    private func waitForRenderingTurn() async {
        let frame = expectation(description: "UIKit has an opportunity to commit a presentation frame")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { frame.fulfill() }
        await fulfillment(of: [frame], timeout: 2)
    }
}

@MainActor
private final class ChromeLayoutTrackingView: UIView {
    private(set) var layoutCount = 0
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCount += 1
    }
}
#endif
