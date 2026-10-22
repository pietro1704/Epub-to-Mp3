#if os(iOS)
import UIKit

@MainActor
enum SettingsChoicePresentation {
    static func present<Value: Equatable>(
        controller: UITableViewController?,
        title: String,
        options: [(String, Value)],
        currentValue: Value,
        apply: @escaping (Value) -> Void
    ) {
        guard let controller else { return }
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (label, value) in options {
            let suffix = value == currentValue ? " ✓" : ""
            alert.addAction(UIAlertAction(title: label + suffix, style: .default) { _ in
                apply(value)
                controller.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(
                x: controller.view.bounds.midX,
                y: controller.view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        controller.present(alert, animated: true)
    }
}
#endif
