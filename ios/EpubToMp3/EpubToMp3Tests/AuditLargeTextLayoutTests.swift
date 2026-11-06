#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class AuditLargeTextLayoutTests: XCTestCase {
    func testAccessibilityTabAccessoryKeepsTextInsideItsCompactSurface() async throws {
        let host = UIViewController()
        let child = UIViewController()
        let mini = MiniPlayerBarUIKitView(usesSystemManagedBottomInset: true)
        child.view = mini
        host.addChild(child)
        host.view.addSubview(mini)
        child.didMove(toParent: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), forChild: child)
        host.view.layoutIfNeeded()
        await Task.yield()
        XCTAssertEqual(mini.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
        mini.frame = CGRect(x: 0, y: 0, width: 320, height: 60)
        mini.layoutIfNeeded()
        XCTAssertEqual(mini.intrinsicContentSize.height, 60, accuracy: 0.5)
        let title = try XCTUnwrap(descendants(mini).compactMap { $0 as? UILabel }
            .first { $0.accessibilityIdentifier == "miniPlayer.chapterTitle" })
        XCTAssertEqual(title.numberOfLines, 2)
        XCTAssertGreaterThan(title.font.pointSize, 15, "The title must still respond to larger text")
        XCTAssertLessThanOrEqual(title.font.lineHeight * CGFloat(title.numberOfLines), mini.bounds.height - 6)
    }

    func testMiniPlayerKeepsPrimaryActionsReachableAcrossTextSizeChanges() throws {
        let host = UIViewController()
        let child = UIViewController()
        let mini = MiniPlayerBarUIKitView()
        child.view = mini
        host.addChild(child)
        host.view.addSubview(mini)
        child.didMove(toParent: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        for category: UIContentSizeCategory in [.large, .accessibilityExtraExtraExtraLarge, .large] {
            host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: child)
            mini.frame = CGRect(x: 0, y: 0, width: 320, height: mini.intrinsicContentSize.height)
            mini.layoutIfNeeded()
            let controls = descendants(mini).compactMap { $0 as? UIButton }
            let play = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "miniPlayer.playPause" })
            XCTAssertFalse(play.isHidden)
            XCTAssertGreaterThanOrEqual(play.bounds.height, 44)
            XCTAssertGreaterThanOrEqual(play.bounds.width, 44)
            XCTAssertLessThanOrEqual(mini.intrinsicContentSize.height, MiniPlayerLayoutMetrics.maximumOverlayHeight)
            for identifier in ["miniPlayer.previous", "miniPlayer.next", "miniPlayer.rate"] {
                XCTAssertEqual(controls.first { $0.accessibilityIdentifier == identifier }?.isHidden,
                    category.isAccessibilityCategory)
            }
            let open = try XCTUnwrap(controls.first { $0.accessibilityIdentifier == "miniPlayer.open" })
            XCTAssertFalse(open.isHidden)
            XCTAssertEqual(open.accessibilityLabel, L10n.string("player.openFullPlayer"))
        }
    }

    func testAccessibilityLibraryWrapsTheFullBookIdentityAndRestoresGrid() async throws {
        let controller = LibraryGridController(metrics: .init())
        let host = UIViewController()
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let books = (0..<2).map { BookEntity(id: "audit-\($0)", title: "Piper Live Portuguese with a complete readable title",
            author: "Author with a complete name", bookmark: Data(), displayFilename: "test.epub", addedAt: .distantPast) }
        controller.apply(model: LibraryGridModel(books: books), animated: false)
        await Task.yield()
        for category: UIContentSizeCategory in [.accessibilityExtraExtraExtraLarge, .large, .accessibilityExtraExtraExtraLarge] {
            host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
            host.view.layoutIfNeeded()
            await Task.yield()
            XCTAssertEqual(controller.traitCollection.preferredContentSizeCategory, category)
            controller.view.frame = host.view.bounds
            controller.collectionView.collectionViewLayout.invalidateLayout()
            controller.collectionView.layoutIfNeeded()
            let cell = try XCTUnwrap(controller.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
            if category.isAccessibilityCategory {
                XCTAssertEqual(cell.bounds.width, 350, accuracy: 1)
                for label in descendants(cell).compactMap({ $0 as? UILabel }) where !label.isHidden {
                    XCTAssertEqual(label.numberOfLines, 0)
                    let height = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                    XCTAssertGreaterThanOrEqual(label.bounds.height, height - 1)
                }
            } else { XCTAssertLessThan(cell.bounds.width, 200) }
        }
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
}
#endif
