#if os(iOS)
import UIKit

@MainActor
enum RuntimeSettingsRows {
    enum Row {
        case models
        case primary
        case model(SpeechModelSnapshot.Entry?)
        case secondary
        case automaticSystemFallback
        case onlineFallback
        case studyLanguage
    }

    static func rowCount(speechModels: SpeechModelLibraryViewState, disclosure: SpeechModelSettingsDisclosure = .init()) -> Int {
        disclosure.rows(modelCount: speechModels.entries.count).count
    }

    static func row(at index: Int, speechModels: SpeechModelLibraryViewState,
                    disclosure: SpeechModelSettingsDisclosure = .init()) -> Row? {
        let rows = disclosure.rows(modelCount: speechModels.entries.count)
        guard rows.indices.contains(index) else { return nil }
        switch rows[index] {
        case .primary: return .primary
        case .summary: return .models
        case let .model(ordinal):
            return .model(ordinal.flatMap { speechModels.orderedEntries.indices.contains($0) ? speechModels.orderedEntries[$0] : nil })
        case .secondary: return .secondary
        case .automaticSystemFallback: return .automaticSystemFallback
        case .onlineFallback: return .onlineFallback
        case .studyLanguage: return .studyLanguage
        }
    }

    static func cell(
        for indexPath: IndexPath,
        tableView: UITableView,
        settings: AppSettings,
        speechModels: SpeechModelLibraryViewState,
        installEvents: [String: SpeechModelInstallEvent],
        termsAcceptance: SpeechModelTermsAcceptanceStore,
        disclosure: SpeechModelSettingsDisclosure = .init(),
        controller: UIViewController,
        rowOverride: Row? = nil, existingCell: UITableViewCell? = nil
    ) -> UITableViewCell {
            switch rowOverride ?? row(at: indexPath.row, speechModels: speechModels, disclosure: disclosure) {
            case .models:
                let cell = existingCell ?? tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("models.title")
                content.secondaryText = SpeechModelSettingsDisclosure.summary(state: speechModels,
                    primary: settings.ttsPreferences.primary, events: installEvents)
                content.secondaryTextProperties.numberOfLines = 0
                content.image = UIImage(systemName: "waveform")
                cell.contentConfiguration = content
                cell.accessibilityIdentifier = "settings.speechModels.disclosure"
                cell.accessibilityValue = L10n.string(disclosure.isExpanded ? "settings.models.expanded" : "settings.models.collapsed")
                cell.accessoryType = disclosure.isExpanded ? .none : .disclosureIndicator
                cell.selectionStyle = disclosure.isExpanded ? .none : .default
                return cell
            case .primary:
                let cell = existingCell ?? tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("settings.audioEngineChoice")
                content.secondaryText = speechModels.displayName(for: (controller as? SettingsScreenController)?.displayedPrimaryVoice
                    ?? settings.ttsPreferences.primary)
                cell.accessibilityIdentifier = "settings.tts.primary"
                cell.accessibilityValue = content.secondaryText
                content.image = UIImage(systemName: "waveform")
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
                return cell
            case .secondary:
                let cell = existingCell ?? tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
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
            case .automaticSystemFallback:
                let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
                cell.configure(title: L10n.string("settings.automaticSystemFallback"),
                               subtitle: L10n.string("settings.automaticSystemFallbackDescription"),
                               isOn: settings.allowAutomaticSystemVoiceFallback,
                               accessibilityIdentifier: "settings.tts.automaticSystemFallback")
                cell.onValueChanged = { [weak controller] isAllowed in
                    guard controller != nil else { return }
                    settings.allowAutomaticSystemVoiceFallback = isAllowed
                }
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
                let cell = existingCell ?? tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("settings.modelLanguage.study")
                content.secondaryText = speechModels.languageTitle(speechModels.studyLanguage)
                cell.contentConfiguration = content
                cell.accessibilityIdentifier = "settings.speechModels.language"
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
                return cell
            case let .model(entry):
                let cell = existingCell ?? tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
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
                    content.secondaryText = speechModels.rowSummary(
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
    static func handleAboutSelection(row: Int) {
        guard row == 2, let url = URL(string: "https://github.com/pietro1704/Epub-to-Mp3") else { return }
        UIApplication.shared.open(url)
    }

}
#endif
