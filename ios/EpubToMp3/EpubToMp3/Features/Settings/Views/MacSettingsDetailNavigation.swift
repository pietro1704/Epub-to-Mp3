#if os(macOS)
import AppKit

/// A native Settings detail destination with explicit back navigation.
@MainActor
final class MacSettingsDetailNavigation: NSViewController {
    private let detail: NSViewController
    private let onBack: () -> Void

    init(detail: NSViewController, onBack: @escaping () -> Void) {
        self.detail = detail
        self.onBack = onBack
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let back = NSButton(title: L10n.string("common.back"), target: self, action: #selector(goBack))
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)
        back.setAccessibilityIdentifier("settings.voiceModels.back")
        let title = NSTextField(labelWithString: L10n.string("settings.voiceModels"))
        title.font = .preferredFont(forTextStyle: .headline)
        let header = NSStackView(views: [back, title])
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        addChild(detail)
        detail.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(detail.view)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            detail.view.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            detail.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detail.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detail.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    @objc private func goBack() { onBack() }
}
#endif
