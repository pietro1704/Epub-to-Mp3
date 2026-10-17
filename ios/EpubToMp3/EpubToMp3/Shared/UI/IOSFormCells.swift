#if os(iOS)
import UIKit

/// Explicit spoken overrides belong to one row, never the next reuse of its cell.
final class IOSContentCell: UITableViewCell {
    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityIdentifier = nil
        accessibilityTraits = []
    }
}

final class IOSInlineTextFieldCell: UITableViewCell, UITextFieldDelegate {
    let titleLabel = UILabel()
    let textField = UITextField()
    private let fieldStack = UIStackView()
    var onTextChanged: ((String) -> Void)?
    var onReturn: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.textAlignment = .right
        textField.clearButtonMode = .whileEditing
        textField.delegate = self
        textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)

        let stack = fieldStack
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(textField)
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    override func layoutSubviews() {
        let vertical = traitCollection.preferredContentSizeCategory.isAccessibilityCategory || bounds.width < 360
        fieldStack.axis = vertical ? .vertical : .horizontal
        fieldStack.alignment = vertical ? .fill : .center
        textField.textAlignment = vertical ? .natural : .right
        super.layoutSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        value: String,
        placeholder: String? = nil,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: UITextAutocapitalizationType = .sentences,
        isEnabled: Bool = true
    ) {
        titleLabel.text = title
        textField.text = value
        textField.placeholder = placeholder
        textField.keyboardType = keyboardType
        textField.autocapitalizationType = autocapitalization
        textField.isEnabled = isEnabled
        textField.textColor = isEnabled ? .label : .secondaryLabel
        textField.accessibilityLabel = title
    }

    @objc
    private func textDidChange() {
        onTextChanged?(textField.text ?? "")
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onReturn?()
        textField.resignFirstResponder()
        return true
    }
}

final class IOSSwitchCell: UITableViewCell {
    let toggleSwitch = UISwitch()
    var onValueChanged: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryView = toggleSwitch
        toggleSwitch.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, subtitle: String? = nil, isOn: Bool, tintColor: UIColor? = nil, accessibilityIdentifier: String? = nil) {
        var content = defaultContentConfiguration()
        content.text = title
        content.secondaryText = subtitle
        content.secondaryTextProperties.numberOfLines = 0
        contentConfiguration = content
        isUserInteractionEnabled = true
        toggleSwitch.isOn = isOn
        toggleSwitch.isEnabled = true
        toggleSwitch.accessibilityIdentifier = accessibilityIdentifier
        toggleSwitch.accessibilityLabel = title
        toggleSwitch.accessibilityHint = subtitle
        if let tintColor {
            toggleSwitch.onTintColor = tintColor
        }
    }

    @objc
    private func valueChanged() {
        onValueChanged?(toggleSwitch.isOn)
    }
}
#endif
