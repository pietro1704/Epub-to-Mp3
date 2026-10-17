#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class NativeFormAccessibilityTests: XCTestCase {
    func testReaderSettingsSlidersFitBelowTheirLabelsOnCompactScreen() throws {
        try verifyReaderSettingsSliders(category: .large)
    }

    func testReaderSettingsSlidersFitAtAccessibilitySizeAfterReload() throws {
        try verifyReaderSettingsSliders(category: .accessibilityExtraExtraExtraLarge)
    }

    private func verifyReaderSettingsSliders(category: UIContentSizeCategory) throws {
        let suite = "reader-settings-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.readerLayout = .paginated
        let controller = ReaderSettingsScreenController(settings: settings)
        let host = UIViewController()
        host.addChild(controller)
        host.setOverrideTraitCollection(UITraitCollection(preferredContentSizeCategory: category), forChild: controller)
        host.view.addSubview(controller.view)
        controller.view.frame = host.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.didMove(toParent: host)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.layoutIfNeeded()
        controller.refresh()
        for index in [IndexPath(row: 1, section: 1), IndexPath(row: 0, section: 0),
                      IndexPath(row: 4, section: 2), IndexPath(row: 1, section: 0),
                      IndexPath(row: 5, section: 2), IndexPath(row: 0, section: 1),
                      IndexPath(row: 1, section: 1)] {
            controller.tableView.scrollToRow(at: index, at: .middle, animated: false)
            controller.tableView.layoutIfNeeded()
            let cell = try XCTUnwrap(controller.tableView.cellForRow(at: index))
            if index.section == 0 || (index.section == 1 && index.row == 0) {
                XCTAssertTrue(descendants(cell).compactMap { $0 as? CompactSlider }.isEmpty,
                              "A reused non-slider row must not retain the previous control.")
                continue
            }
            let slider = try XCTUnwrap(descendants(cell).compactMap { $0 as? CompactSlider }.first)
            let sliderFrame = slider.convert(slider.bounds, to: cell.contentView)
            XCTAssertGreaterThanOrEqual(sliderFrame.minY, 0)
            XCTAssertLessThanOrEqual(sliderFrame.maxY, cell.contentView.bounds.height + 1)
            let labels = descendants(cell).compactMap { $0 as? UILabel }.filter { $0.text?.isEmpty == false }
            XCTAssertGreaterThanOrEqual(labels.count, 2, "The title and current value must remain visible with the slider.")
            for label in labels {
                let frame = label.convert(label.bounds, to: cell.contentView)
                XCTAssertLessThanOrEqual(frame.maxY, sliderFrame.minY, "Slider must not overlap \(label.text ?? "")")
                XCTAssertGreaterThan(label.bounds.width, 0)
                let required = label.sizeThatFits(CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude)).height
                XCTAssertGreaterThanOrEqual(label.bounds.height, required - 1)
            }
        }
        settings.readerLayout = .scrolling
        controller.refresh()
        let margin = IndexPath(row: 3, section: 2)
        controller.tableView.scrollToRow(at: margin, at: .middle, animated: false)
        controller.tableView.layoutIfNeeded()
        let cell = try XCTUnwrap(controller.tableView.cellForRow(at: margin))
        XCTAssertEqual(descendants(cell).compactMap { $0 as? CompactSlider }.count, 1,
                       "Changing reading mode must keep exactly one margin control.")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

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
