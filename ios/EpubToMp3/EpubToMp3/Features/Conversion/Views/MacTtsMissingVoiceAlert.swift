#if os(macOS)
import AppKit

/// The macOS counterpart of the iOS missing-voice alert: no installed model can read
/// the book's language, so the listener chooses how to continue. Nothing is
/// downloaded without confirmation, and "Download a model" opens the Models screen
/// on the book's language.
@MainActor
enum MacTtsMissingVoiceAlert {
    enum Action: Equatable { case recommended, models, system, cancel }

    /// Buttons in order; the disabled ones are not offered.
    static func actions(hasRecommended: Bool, systemAvailable: Bool) -> [Action] {
        (hasRecommended ? [.recommended] : []) + [.models] + (systemAvailable ? [.system] : []) + [.cancel]
    }

    static func makeAlert(language: String, recommended: SpeechModelSnapshot.Entry?, systemAvailable: Bool) -> NSAlert {
        let languageName = Locale.current.localizedString(forIdentifier: language) ?? language
        var message = L10n.string("tts.missingVoice.message", languageName)
        if let recommended { message += "\n" + L10n.string("tts.missingVoice.recommended", recommended.presentation.modelName) }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("tts.missingVoice.title")
        alert.informativeText = message
        for action in actions(hasRecommended: recommended != nil, systemAvailable: systemAvailable) {
            alert.addButton(withTitle: title(for: action))
        }
        alert.window.setAccessibilityIdentifier("tts.missingVoice.alert")
        return alert
    }

    private static func title(for action: Action) -> String {
        switch action {
        case .recommended: return L10n.string("tts.missingVoice.downloadRecommended")
        case .models: return L10n.string("tts.missingVoice.openSettings")
        case .system: return L10n.string("tts.missingVoice.system")
        case .cancel: return L10n.string("common.cancel")
        }
    }

    static func choose(for mismatch: TtsLanguageMismatch, client: SpeechModelLibraryClient = .shared,
                       isCurrent: @escaping () -> Bool) async -> TtsRecoveryAlert.Choice? {
        let snapshot = try? await client.recoverySnapshot(language: mismatch.language)
        guard !Task.isCancelled, isCurrent() else { return nil }
        let recommended = snapshot.flatMap { TtsMissingVoicePolicy.recommended(in: $0) }
        let voices = TtsMissingVoicePreflight.installedSystemVoices()
        let systemVoice = InstalledSpeechVoicePolicy.select(language: mismatch.language, voices: voices)
        let alert = makeAlert(language: mismatch.language, recommended: recommended, systemAvailable: systemVoice != nil)
        let offered = actions(hasRecommended: recommended != nil, systemAvailable: systemVoice != nil)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard !Task.isCancelled, isCurrent(), offered.indices.contains(index) else { return nil }
        switch offered[index] {
        case .cancel: return nil
        case .system:
            guard let voice = voices.first(where: { $0.identifier == systemVoice }) else { return nil }
            return .init(candidate: TtsRecoveryCandidate(name: voice.name, selection: .systemDefault), language: mismatch.language)
        case .models:
            openModels(language: mismatch.language)
            return nil
        case .recommended:
            // The existing flow confirms the download, installs it and returns the candidate.
            return await TtsLanguageDownload.offer(for: mismatch, isCurrent: isCurrent)
        }
    }

    /// The Models screen, on the book's language, as a sheet over the current window.
    static func openModels(language: String) {
        guard let app = NSApp.delegate as? EpubToMp3App,
              let host = NSApp.keyWindow?.contentViewController else { return }
        let models = MacModelsViewController(settings: app.settings, focusLanguage: language)
        var sheet: NSViewController?
        let container = MacSettingsDetailNavigation(detail: models) { [weak host] in
            if let sheet { host?.dismiss(sheet) }
        }
        sheet = container
        container.preferredContentSize = NSSize(width: 760, height: 620)
        host.presentAsSheet(container)
    }
}
#endif
