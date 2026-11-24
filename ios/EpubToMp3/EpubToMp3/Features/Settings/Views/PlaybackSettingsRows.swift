#if os(iOS)
import UIKit

@MainActor
struct PlaybackSettingsRows {
    let tableView: UITableView
    let settings: AppSettings

    func cell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.row == 2 {
            content.text = L10n.string("settings.remoteButtons")
            content.secondaryText = settings.remoteButtonMode.title
            content.image = UIImage(systemName: "car")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "settings.remoteButtons"
            return cell
        }
        content.text = indexPath.row == 0
            ? L10n.string("settings.skipForward")
            : L10n.string("settings.skipBackward")
        let seconds = indexPath.row == 0 ? settings.playbackForwardSeconds : settings.playbackBackwardSeconds
        content.secondaryText = L10n.string("settings.seconds", Int(seconds))
        content.image = UIImage(systemName: indexPath.row == 0 ? "goforward" : "gobackward")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = indexPath.row == 0 ? "settings.skipForward" : "settings.skipBackward"
        return cell
    }

}
#endif
