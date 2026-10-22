#if os(iOS)
import UIKit

@MainActor
enum SettingsAlertPresentation {
    static func info(on controller: UIViewController, title: String, message: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("library.ok"), style: .default))
        controller.present(alert, animated: true)
    }

    static func destructive(
        on controller: UIViewController,
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: buttonTitle, style: .destructive) { _ in action() })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

}
#endif
