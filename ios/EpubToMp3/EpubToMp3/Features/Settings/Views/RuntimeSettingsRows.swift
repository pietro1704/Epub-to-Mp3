#if os(iOS)
import UIKit

@MainActor
enum RuntimeSettingsRows {
    enum Row {
        case primary
        case cellular
        case model(SpeechModelSnapshot.Entry?)
        case secondary
        case onlineFallback
        case studyLanguage
    }

    static func rowCount(speechModels: SpeechModelLibraryViewState) -> Int {
        5 + max(1, speechModels.entries.count)
    }

    static func row(at index: Int, speechModels: SpeechModelLibraryViewState) -> Row? {
        if index == 0 { return .primary }
        if index == 1 { return .cellular }
        let models = speechModels.orderedEntries
        let modelCount = max(1, models.count)
        if index < 2 + modelCount {
            return .model(models.indices.contains(index - 2) ? models[index - 2] : nil)
        }
        if index == 2 + modelCount { return .secondary }
        if index == 3 + modelCount { return .onlineFallback }
        if index == 4 + modelCount { return .studyLanguage }
        return nil
    }

    static func cell(
        for indexPath: IndexPath,
        tableView: UITableView,
        settings: AppSettings,
        speechModels: SpeechModelLibraryViewState,
        installEvents: [String: SpeechModelInstallEvent],
        termsAcceptance: SpeechModelTermsAcceptanceStore,
        controller: UIViewController
    ) -> UITableViewCell {
            switch row(at: indexPath.row, speechModels: speechModels) {
            case .primary:
                let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("settings.audioEngineChoice")
                content.secondaryText = speechModels.displayName(for: settings.ttsPreferences.primary)
                cell.accessibilityIdentifier = "settings.tts.primary"
                cell.accessibilityValue = content.secondaryText
                content.image = UIImage(systemName: "waveform")
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
                return cell
            case .cellular:
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
            case .secondary:
                let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("settings.secondaryVoice")
                content.secondaryText = settings.ttsPreferences.secondary
                    .map(speechModels.displayName(for:)) ?? L10n.string("settings.noSecondary")
                cell.accessibilityIdentifier = "settings.tts.secondary"
                cell.accessibilityValue = content.secondaryText
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
                return cell
            case .onlineFallback:
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
            case .studyLanguage:
                let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("settings.modelLanguage.study")
                content.secondaryText = speechModels.languageTitle(speechModels.studyLanguage)
                cell.contentConfiguration = content
                cell.accessibilityIdentifier = "settings.speechModels.language"
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
                return cell
            case let .model(entry):
                let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                guard let entry else {
                    content.text = L10n.string("settings.voiceModels")
                    content.secondaryText = L10n.string("settings.modelState.notInspected")
                    content.image = UIImage(systemName: "waveform.badge.magnifyingglass")
                    cell.contentConfiguration = content
                    cell.accessoryType = .none
                    cell.selectionStyle = .none
                    return cell
                }
                let installEvent = installEvents[entry.identity.modelID]
                content.text = speechModels.displayName(for: entry)
                if let installEvent {
                    content.secondaryText = speechModels.installStatus(for: installEvent)
                    if installEvent.isActive {
                        content.secondaryText = "\(content.secondaryText ?? "") · "
                            + L10n.string("settings.modelInstall.cancel")
                    }
                } else {
                    content.secondaryText = speechModels.details(
                        for: entry,
                        configuredSelections: settings.configuredNarrationSelections
                    )
                }
                let selections = [settings.ttsPreferences.primary, settings.ttsPreferences.secondary]
                    .compactMap { $0 }
                let terms = termsAcceptance.isAccepted(
                    modelID: entry.identity.modelID,
                    fingerprint: entry.licence.termsFingerprint
                )
                let actions = speechModels.actions(
                    for: entry,
                    configuredSelections: selections,
                    installEvent: installEvent,
                    termsAccepted: terms
                )
                cell.accessibilityIdentifier = "settings.speechModel.\(entry.identity.modelID)"
                cell.accessibilityValue = content.secondaryText
                cell.accessoryType = actions.available.isEmpty ? .none : .disclosureIndicator
                cell.selectionStyle = actions.available.isEmpty ? .none : .default
                content.image = UIImage(systemName: "waveform.badge.plus")
                cell.contentConfiguration = content
                return cell
            case .none:
                return UITableViewCell()
            }
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
