#if os(iOS)
import UIKit

final class IOSInlineTextFieldCell: UITableViewCell, UITextFieldDelegate {
    let titleLabel = UILabel()
    let textField = UITextField()
    var onTextChanged: ((String) -> Void)?
    var onReturn: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.textAlignment = .right
        textField.clearButtonMode = .whileEditing
        textField.delegate = self
        textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)

        let stack = UIStackView(arrangedSubviews: [titleLabel, textField])
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
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
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

    func configure(title: String, subtitle: String? = nil, isOn: Bool, tintColor: UIColor? = nil) {
        var content = defaultContentConfiguration()
        content.text = title
        content.secondaryText = subtitle
        content.secondaryTextProperties.numberOfLines = 2
        contentConfiguration = content
        toggleSwitch.isOn = isOn
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
