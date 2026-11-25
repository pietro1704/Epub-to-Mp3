#if os(macOS)
import AppKit

/// Building blocks for the macOS Settings screen, organized like the Linux
/// (Flutter) client: an accent section title, a rounded card of rows and an
/// optional footer (MAC-SETTINGS-TABS-LIKE-LINUX).
/// The rounded group background; redrawn on appearance changes.
final class MacSettingsCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
}

@MainActor
enum MacSettingsSections {
    static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .controlAccentColor
        label.setAccessibilityRole(.staticText)
        return label
    }

    static func footer(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .readableSecondaryLabel
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A group of rows on a rounded background, separated by thin dividers.
    static func card(_ rows: [NSView]) -> NSView {
        let card = MacSettingsCard()
        var arranged: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                arranged.append(divider)
            }
            arranged.append(row)
        }
        let stack = NSStackView(views: arranged)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        arranged.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return card
    }

    /// One settings row: symbol, title with an optional subtitle, then the trailing control.
    static func row(title: String, subtitle: String? = nil, symbol: String? = nil,
                    accessory: NSView? = nil) -> NSView {
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let texts = NSStackView(views: [titleLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let subtitle {
            let detail = NSTextField(wrappingLabelWithString: subtitle)
            detail.font = .preferredFont(forTextStyle: .subheadline)
            detail.textColor = .readableSecondaryLabel
            detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            texts.addArrangedSubview(detail)
        }
        texts.setHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = []
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
            views.append(icon)
        }
        views.append(texts)
        if let accessory {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(accessory)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        return row
    }

    /// A row that opens a page; the chevron button carries the action and
    /// a click anywhere on the row forwards to it.
    static func disclosureRow(title: String, subtitle: String? = nil, symbol: String? = nil,
                              identifier: String, target: AnyObject, action: Selector) -> (row: NSView, button: NSButton) {
        let chevron = NSButton(title: "", target: target, action: action)
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.imagePosition = .imageOnly
        chevron.isBordered = false
        chevron.setAccessibilityLabel(title)
        chevron.setAccessibilityIdentifier(identifier)
        let row = row(title: title, subtitle: subtitle, symbol: symbol, accessory: chevron)
        let click = NSClickGestureRecognizer(target: chevron, action: #selector(NSButton.performClick(_:)))
        row.addGestureRecognizer(click)
        return (row, chevron)
    }

    static func switchControl(isOn: Bool, label: String, identifier: String,
                              target: AnyObject, action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.state = isOn ? .on : .off
        toggle.target = target
        toggle.action = action
        toggle.setAccessibilityLabel(label)
        toggle.setAccessibilityIdentifier(identifier)
        return toggle
    }
}
#endif
