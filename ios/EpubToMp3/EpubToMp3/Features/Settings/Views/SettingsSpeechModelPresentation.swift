#if os(iOS)
import UIKit

/// Settings keeps a single Models row; models themselves live in the Models screen.
extension SettingsScreenController {
    func reloadSpeechModels() {
        modelLibrary.reload()
    }

    var modelSummaryPath: IndexPath {
        IndexPath(row: 0, section: SettingsSection.runtime.rawValue)
    }

    func modelsCell(at path: IndexPath, existingCell: UITableViewCell? = nil) -> UITableViewCell {
        let cell = existingCell ?? tableView.dequeueReusableCell(withIdentifier: "Cell", for: path)
        var content = cell.defaultContentConfiguration()
        content.text = L10n.string("models.title")
        content.secondaryText = SpeechModelSettingsSummary.text(state: speechModelState,
            primary: settings.ttsPreferences.primary, events: speechModelInstallEvents)
        content.secondaryTextProperties.numberOfLines = 0
        content.image = UIImage(systemName: "waveform")
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings.speechModels.disclosure"
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        return cell
    }

    func applyInstallEvent(_ event: SpeechModelInstallEvent) {
        guard modelLibrary.apply(event) else { return }
        refreshInstallProgress()
    }

    func refreshInstallProgress() {
        // Configure the live cell directly: reloading a self-sizing section makes
        // UIKit replace rows and recompute estimated heights for every byte event.
        UIView.performWithoutAnimation {
            if let cell = tableView.cellForRow(at: modelSummaryPath) {
                _ = modelsCell(at: modelSummaryPath, existingCell: cell)
            }
            // Self-sizing invalidation is iOS 16+; re-measure the live rows without replacing them.
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }
}
#endif
