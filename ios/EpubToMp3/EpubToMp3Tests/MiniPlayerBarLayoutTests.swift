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

    func testOverlayMaterialExtendsThroughBottomSafeArea() throws {
        let hostController = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = hostController
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        hostController.additionalSafeAreaInsets.bottom = 34
        hostController.loadViewIfNeeded()

        let miniPlayer = MiniPlayerBarUIKitView()
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        hostController.view.addSubview(miniPlayer)
        NSLayoutConstraint.activate([
            miniPlayer.leadingAnchor.constraint(equalTo: hostController.view.leadingAnchor),
            miniPlayer.trailingAnchor.constraint(equalTo: hostController.view.trailingAnchor),
            miniPlayer.bottomAnchor.constraint(equalTo: hostController.view.bottomAnchor),
            miniPlayer.heightAnchor.constraint(equalToConstant: MiniPlayerLayoutMetrics.maximumOverlayHeight),
        ])
        hostController.view.layoutIfNeeded()

        XCTAssertGreaterThan(miniPlayer.safeAreaInsets.bottom, 0)
        let materialView = try XCTUnwrap(
            miniPlayer.subviews.first(where: { $0 is AdaptiveMaterialView })
        )
        XCTAssertEqual(materialView.frame.maxY, miniPlayer.bounds.maxY, accuracy: 0.5)

        let contentStack = try XCTUnwrap(
            miniPlayer.subviews.first(where: { $0 is UIStackView })
        )
        XCTAssertEqual(
            contentStack.frame.midY,
            miniPlayer.safeAreaLayoutGuide.layoutFrame.midY,
            accuracy: 0.5
        )
    }

    func testOpenButtonActivatesFullPlayerAndAnnouncesDisplayedMetadata() throws {
        let suite = "mini-player.layout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let player = AudioPlayer()
        let library = LibraryStore(defaults: defaults, defaultsKey: "books")
        let miniPlayer = MiniPlayerBarUIKitView()
        var openCount = 0
        miniPlayer.configure(
            player: player,
            playbackClock: player.playbackClock,
            library: library,
            onTap: { openCount += 1 }
        )

        let openButton = try XCTUnwrap(button(in: miniPlayer, identifier: "miniPlayer.open"))
        XCTAssertFalse(openButton.accessibilityValue?.isEmpty ?? true)
        openButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(openCount, 1)
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

    private func button(in view: UIView, identifier: String) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
            return button
        }
        for subview in view.subviews {
            if let button = button(in: subview, identifier: identifier) {
                return button
            }
        }
        return nil
    }
}
#endif
