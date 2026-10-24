#if os(iOS)
import UIKit

@MainActor
enum RuntimeSettingsRows {
    static func cell(for indexPath: IndexPath, tableView: UITableView, settings: AppSettings, controller: UIViewController) -> UITableViewCell {
            if indexPath.row == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("settings.audioEngineChoice")
                content.secondaryText = settings.primaryNarrationDisplayName
                cell.accessibilityIdentifier = "settings.tts.primary"
                cell.accessibilityValue = settings.primaryNarrationDisplayName
                content.image = UIImage(systemName: "waveform")
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                return cell
            }
            if indexPath.row == 1 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
                cell.configure(
                    title: L10n.string("settings.allowCellularAudio"),
                    subtitle: L10n.string("settings.allowCellularAudioDescription"),
                    isOn: settings.allowCellularAudioConversion
                )
                cell.onValueChanged = { [weak controller] isOn in
                    guard controller != nil else { return }
                    settings.allowCellularAudioConversion = isOn
                    LocalAudioConversionScheduler.shared.setAllowsCellularConversion(isOn)
                }
                cell.accessibilityIdentifier = "settings.allowCellularAudio"
                return cell
            }
            if indexPath.row == 3 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("settings.secondaryVoice")
                content.secondaryText = settings.secondaryNarrationDisplayName
                cell.accessibilityIdentifier = "settings.tts.secondary"
                cell.accessibilityValue = content.secondaryText
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                return cell
            }
            if indexPath.row == 4 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
                cell.configure(title: L10n.string("settings.onlineFallback"),
                               subtitle: L10n.string("settings.onlineFallbackDescription"),
                               isOn: settings.allowOnlineAudioFallback, accessibilityIdentifier: "settings.tts.onlineConsent")
                cell.onValueChanged = { [weak controller] isAllowed in
                    guard controller != nil else { return }
                    settings.allowOnlineAudioFallback = isAllowed
                    tableView.reloadData()
                }
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("settings.piperInstall")
            content.secondaryText = LocalSpeechModelReadiness.isSelectionInstalled(settings.ttsPreferences.primary) ? L10n.string("settings.piperInstalled") : L10n.string("settings.piperNotInstalled")
            content.image = UIImage(systemName: "arrow.down.circle")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
    }
    static func backendCell(for indexPath: IndexPath, tableView: UITableView, settings: AppSettings, controller: UIViewController) -> UITableViewCell {
            if indexPath.row == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "TextField", for: indexPath) as! IOSInlineTextFieldCell
                cell.configure(
                    title: L10n.string("settings.url"),
                    value: settings.backendURL,
                    placeholder: "https://rust-backend.example",
                    keyboardType: .URL,
                    autocapitalization: .none,
                    isEnabled: settings.remoteBackendControlsEnabled
                )
                cell.onTextChanged = { [weak controller] text in
                    guard controller != nil else { return }
                    settings.backendURL = text
                 }
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("settings.urlNotValid")
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemRed
            cell.contentConfiguration = content
            let showWarning = settings.remoteBackendControlsEnabled && settings.resolvedBaseURL == nil
            cell.isHidden = !showWarning
            cell.selectionStyle = .none
            return cell
    }
    static func handleAboutSelection(row: Int) {
        guard row == 2, let url = URL(string: "https://github.com/pietro1704/Epub-to-Mp3") else { return }
        UIApplication.shared.open(url)
    }

}
#endif
