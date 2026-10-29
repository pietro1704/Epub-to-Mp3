#if os(iOS)
import UIKit

@MainActor
struct ReaderSettingsRows {
    let tableView: UITableView
    let settings: AppSettings

    func cell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.fontSize")
            content.secondaryText = L10n.string("settings.fontStep", settings.readerFontSize + 1, 5)
            content.image = UIImage(systemName: "textformat.size")
        case 1:
            content.text = L10n.string("settings.font")
            content.secondaryText = ReaderFontCatalog.title(for: settings.selectedReaderFontFamily)
            content.image = UIImage(systemName: "textformat")
        case 2:
            content.text = L10n.string("settings.theme")
            content.secondaryText = settings.readerTheme.displayName
            content.image = UIImage(systemName: "paintpalette")
        case 3:
            content.text = L10n.string("settings.layout")
            content.secondaryText = settings.readerLayout.displayName
            content.image = UIImage(systemName: "doc.text")
        case 4:
            content.text = L10n.string("settings.lineSpacing")
            content.secondaryText = "\(Int(settings.readerLineSpacing)) pt"
            content.image = UIImage(systemName: "arrow.up.and.down.text.horizontal")
        case 5:
            content.text = L10n.string("settings.margin")
            content.secondaryText = "\(Int(settings.readerMargin)) pt"
            content.image = UIImage(systemName: "rectangle.compress.vertical")
        default:
            content.text = L10n.string("settings.autoScroll")
            content.secondaryText = nil
            content.image = UIImage(systemName: "arrow.down.to.line")
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText
        cell.accessibilityHint = indexPath.row == 6
            ? L10n.string("settings.autoScrollHint")
            : L10n.string("settings.openOptionHint")
        if indexPath.row == 6 {
            cell.accessoryType = settings.readerAutoScroll ? .checkmark : .none
        }
        return cell
    }

}
#endif
