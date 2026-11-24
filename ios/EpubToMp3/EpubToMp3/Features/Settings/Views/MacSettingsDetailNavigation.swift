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
        let title = NSTextField(labelWithString: detail.title ?? L10n.string("settings.voiceModels"))
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

#if os(macOS)
extension NSViewController {
    /// Pushes `detail` over this controller's whole view with the Back header of `MacSettingsDetailNavigation`.
    /// Returns the pushed container; popping removes it and unhides what it covered.
    @discardableResult
    func pushDetail(_ detail: NSViewController, onPop: (() -> Void)? = nil) -> NSViewController {
        let covered = view.subviews.map { ($0, $0.isHidden) }
        var container: MacSettingsDetailNavigation?
        let navigation = MacSettingsDetailNavigation(detail: detail) {
            container?.view.removeFromSuperview()
            container?.removeFromParent()
            covered.forEach { $0.0.isHidden = $0.1 }
            onPop?()
        }
        container = navigation
        covered.forEach { $0.0.isHidden = true }
        addChild(navigation)
        navigation.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(navigation.view)
        NSLayoutConstraint.activate([
            navigation.view.topAnchor.constraint(equalTo: view.topAnchor),
            navigation.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            navigation.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navigation.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        return navigation
    }
}
#endif
