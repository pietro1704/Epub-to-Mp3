import XCTest
@testable import EpubToMp3

#if os(iOS)
import UIKit

@MainActor
final class MiniPlayerBarLayoutTests: XCTestCase {
    func testOverlayMiniPlayerUsesItsIntrinsicContentHeight() {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(miniPlayer)

        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            miniPlayer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        XCTAssertEqual(miniPlayer.bounds.height, miniPlayer.intrinsicContentSize.height, accuracy: 0.5)
    }

    func testContentStackCentersWithinExtendedOverlay() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(miniPlayer)

        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            miniPlayer.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            miniPlayer.heightAnchor.constraint(equalToConstant: MiniPlayerLayoutMetrics.maximumOverlayHeight),
        ])
        host.layoutIfNeeded()

        let materialView = try XCTUnwrap(
            miniPlayer.subviews.first(where: { $0 is AdaptiveMaterialView })
        )
        let contentStack = try XCTUnwrap(
            miniPlayer.subviews.first(where: { $0 is UIStackView })
        )
        let materialCenter = materialView.convert(
            CGPoint(x: materialView.bounds.midX, y: materialView.bounds.midY),
            to: miniPlayer
        )
        let contentCenter = contentStack.convert(
            CGPoint(x: contentStack.bounds.midX, y: contentStack.bounds.midY),
            to: miniPlayer
        )

        XCTAssertEqual(contentCenter.y, materialCenter.y, accuracy: 0.5)
    }

    func testSystemAccessoryExcludesAnAdditionalBottomSafeAreaInset() {
        let miniPlayer = MiniPlayerBarUIKitView(usesSystemManagedBottomInset: true)

        XCTAssertEqual(miniPlayer.intrinsicContentSize.height, 52, accuracy: 0.5)
    }

    func testOverlayMaximumHeightPreservesCompactControlsAndLargeSafeArea() {
        XCTAssertEqual(MiniPlayerLayoutMetrics.contentHeight, 52, accuracy: 0.5)
        XCTAssertEqual(MiniPlayerLayoutMetrics.maximumBottomSafeAreaInset, 44, accuracy: 0.5)
        XCTAssertEqual(
            MiniPlayerLayoutMetrics.maximumOverlayHeight,
            MiniPlayerLayoutMetrics.contentHeight + MiniPlayerLayoutMetrics.maximumBottomSafeAreaInset,
            accuracy: 0.5
        )
        XCTAssertEqual(MiniPlayerLayoutMetrics.maximumOverlayHeight, 96, accuracy: 0.5)
    }
}
#endif
