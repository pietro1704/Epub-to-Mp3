#if os(iOS)
import UIKit
#endif

extension SilenceTrim {
    var title: String { L10n.string("silenceTrim.level.\(rawValue)") }
}

#if os(iOS)
/// The level row and its choices, shared by Settings and the manual conversion form.
@MainActor
enum SilenceTrimControl {
    static func configure(_ cell: UITableViewCell, level: SilenceTrim, accessibilityIdentifier: String) {
        var content = cell.defaultContentConfiguration()
        content.text = L10n.string("silenceTrim.title")
        content.secondaryText = "\(level.title)\n\(L10n.string("silenceTrim.description"))"
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = accessibilityIdentifier
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = level.title
        cell.accessibilityHint = L10n.string("silenceTrim.description")
        cell.accessibilityTraits = .button
    }

    static func picker(from table: UITableView, at indexPath: IndexPath,
                       onChoose: @escaping (SilenceTrim) -> Void) -> UIAlertController {
        let alert = UIAlertController(title: L10n.string("silenceTrim.title"), message: nil,
                                      preferredStyle: .actionSheet)
        for level in SilenceTrim.allCases {
            alert.addAction(UIAlertAction(title: level.title, style: .default) { _ in onChoose(level) })
        }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = table
        alert.popoverPresentationController?.sourceRect = table.rectForRow(at: indexPath)
        return alert
    }
}
#endif
