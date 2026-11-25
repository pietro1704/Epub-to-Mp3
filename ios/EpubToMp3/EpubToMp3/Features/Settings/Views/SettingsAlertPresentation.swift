#if os(iOS)
import UIKit

@MainActor
enum SettingsAlertPresentation {
    static func actionSheet(
        _ alert: UIAlertController,
        on controller: UIViewController,
        tableView: UITableView,
        source: IndexPath
    ) {
        // UIKit throws when an alert has two cancel actions: add ours only when the caller did not.
        if !alert.actions.contains(where: { $0.style == .cancel }) {
            alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        }
        alert.popoverPresentationController?.sourceView = tableView
        alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: source)
        controller.present(alert, animated: true)
    }

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

    static func confirmModelRemoval(
        _ entry: SpeechModelSnapshot.Entry,
        state: SpeechModelLibraryViewState,
        on controller: UIViewController,
        remove: @escaping () -> Void
    ) {
        let alert = UIAlertController(
            title: L10n.string("settings.modelRemove.confirmTitle", state.displayName(for: entry)),
            message: L10n.string("settings.modelRemove.confirmMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.remove"), style: .destructive) { _ in
            remove()
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        controller.present(alert, animated: true)
    }

}
#endif
