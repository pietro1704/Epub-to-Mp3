#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class NativeFormAccessibilityTests: XCTestCase {
    func testReusedContentCellDropsThePreviousDisabledActionTraits() {
        let cell = IOSContentCell(style: .default, reuseIdentifier: nil)
        let defaultTraits = cell.accessibilityTraits
        cell.accessibilityTraits = [.button, .notEnabled]
        cell.prepareForReuse()
        XCTAssertEqual(cell.accessibilityTraits, defaultTraits)
    }

    func testInlineFieldKeepsLocalizedTitleReadableAtAccessibilitySize() throws {
        let controller = UIViewController()
        let cell = IOSInlineTextFieldCell(style: .default, reuseIdentifier: nil)
        cell.configure(title: "Intervalo de navegação para o próximo capítulo", value: "60")
        cell.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            cell.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            cell.topAnchor.constraint(equalTo: controller.view.topAnchor),
        ])
        let host = UIViewController()
        host.addChild(controller)
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        host.setOverrideTraitCollection(
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge),
            forChild: controller
        )
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        cell.bounds.size.width = 320
        cell.setNeedsLayout()
        cell.layoutIfNeeded()
        let fittingHeight = cell.systemLayoutSizeFitting(
            CGSize(width: 320, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        cell.heightAnchor.constraint(equalToConstant: fittingHeight).isActive = true
        controller.view.layoutIfNeeded()
        let titleHeight = cell.titleLabel.sizeThatFits(
            CGSize(width: cell.titleLabel.bounds.width, height: .greatestFiniteMagnitude)
        ).height
        XCTAssertEqual(cell.titleLabel.numberOfLines, 0)
        XCTAssertGreaterThanOrEqual(cell.titleLabel.bounds.height, titleHeight - 1)
        XCTAssertGreaterThanOrEqual(cell.textField.frame.minY, cell.titleLabel.frame.maxY)
        XCTAssertEqual(cell.textField.accessibilityLabel, cell.titleLabel.text)
    }

    func testSwitchHasItsOwnAccessibleNameAndUnrestrictedExplanation() {
        let cell = IOSSwitchCell(style: .default, reuseIdentifier: nil)
        cell.configure(title: "Automatic scrolling", subtitle: "A long explanation", isOn: true)
        XCTAssertEqual(cell.toggleSwitch.accessibilityLabel, "Automatic scrolling")
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.secondaryTextProperties.numberOfLines, 0)
    }
}
#endif
