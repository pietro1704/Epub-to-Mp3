import Foundation

enum PointPresetScale {
    static let font = [14.0, 17, 20, 24, 28]
    static let lineSpacing = Array(stride(from: 0.0, through: 16, by: 2))
    static let margin = Array(stride(from: 16.0, through: 80, by: 4))
    static let macMargin = [16.0, 24, 32, 48, 64]
    static let macKerning = [-1.0, 0, 0.5, 1, 2, 3]

    static func nearestIndex(to value: Double, in presets: [Double]) -> Int {
        presets.indices.min { abs(presets[$0] - value) < abs(presets[$1] - value) } ?? 0
    }

    static func preserving(_ current: Double, in presets: [Double]) -> [Double] {
        guard current.isFinite else { return presets }
        return Array(Set(presets + [current])).sorted()
    }

    static func label(_ value: Double) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal) + " pt"
    }
}

#if os(iOS)
import UIKit

/// A native slider whose reachable positions are the existing preset choices.
final class PointPresetSlider: UISlider {
    private(set) var presets: [Double] = []
    var onPointChange: ((Double) -> Void)?
    var selectedPointValue: Double { presets.indices.contains(Int(value)) ? presets[Int(value)] : 0 }

    func configure(presets: [Double], current: Double) {
        self.presets = PointPresetScale.preserving(current, in: presets)
        minimumValue = 0
        maximumValue = Float(max(0, self.presets.count - 1))
        value = Float(PointPresetScale.nearestIndex(to: current, in: self.presets))
        removeTarget(self, action: #selector(snapped), for: .valueChanged)
        addTarget(self, action: #selector(snapped), for: .valueChanged)
        accessibilityValue = PointPresetScale.label(selectedPointValue)
    }

    @objc private func snapped() {
        value = value.rounded()
        accessibilityValue = PointPresetScale.label(selectedPointValue)
        onPointChange?(selectedPointValue)
    }

    override func accessibilityIncrement() { step(1) }
    override func accessibilityDecrement() { step(-1) }

    private func step(_ direction: Float) {
        guard isEnabled else { return }
        value += direction
        sendActions(for: .valueChanged)
    }
}

final class PointPresetCell: UITableViewCell {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    let slider = PointPresetSlider()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.font = .preferredFont(forTextStyle: .body)
        valueLabel.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.textColor = .secondaryLabel
        for label in [titleLabel, valueLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        let stack = UIStackView(arrangedSubviews: [titleLabel, valueLabel, slider])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func make(in table: UITableView, title: String, identifier: String, presets: [Double],
                     current: Double, onChange: @escaping (Double) -> Void) -> PointPresetCell {
        let cell = (table.dequeueReusableCell(withIdentifier: "PointPreset") as? PointPresetCell)
            ?? PointPresetCell(style: .default, reuseIdentifier: "PointPreset")
        cell.titleLabel.text = title
        cell.valueLabel.text = PointPresetScale.label(current)
        cell.accessibilityIdentifier = identifier + ".row"
        cell.slider.accessibilityIdentifier = identifier
        cell.slider.accessibilityLabel = title
        cell.slider.configure(presets: presets, current: current)
        cell.slider.onPointChange = { [weak cell] value in
            cell?.valueLabel.text = PointPresetScale.label(value)
            onChange(value)
        }
        return cell
    }
}
#elseif os(macOS)
import AppKit

final class MacPointPresetControl: NSStackView {
    let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")
    private let presets: [Double]
    private let onChange: (Double) -> Void

    init(presets: [Double], current: Double, title: String, identifier: String,
         onChange: @escaping (Double) -> Void) {
        self.presets = PointPresetScale.preserving(current, in: presets)
        self.onChange = onChange
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        slider.minValue = 0
        slider.maxValue = Double(max(0, self.presets.count - 1))
        slider.numberOfTickMarks = self.presets.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.doubleValue = Double(PointPresetScale.nearestIndex(to: current, in: self.presets))
        slider.target = self
        slider.action = #selector(changed)
        slider.setAccessibilityLabel(title)
        slider.setAccessibilityIdentifier(identifier)
        valueLabel.stringValue = PointPresetScale.label(current)
        addArrangedSubview(valueLabel)
        addArrangedSubview(slider)
        slider.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func changed() {
        let index = min(max(0, Int(slider.doubleValue.rounded())), presets.count - 1)
        guard presets.indices.contains(index) else { return }
        slider.doubleValue = Double(index)
        valueLabel.stringValue = PointPresetScale.label(presets[index])
        slider.setAccessibilityValue(valueLabel.stringValue)
        onChange(presets[index])
    }
}
#endif
