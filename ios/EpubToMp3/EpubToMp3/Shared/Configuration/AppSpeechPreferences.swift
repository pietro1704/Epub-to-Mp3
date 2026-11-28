import Foundation

/// The speech surface of `AppSettings`, kept for its callers; the values and
/// their rules belong to `SpeechPreferences`.
extension AppSettings {
    var primaryTtsSelection: TtsSelection { speechPreferences.primaryTtsSelection }
    var secondaryTtsSelection: TtsSelection? { speechPreferences.secondaryTtsSelection }
    var narratesFootnotes: Bool {
        get { speechPreferences.narratesFootnotes }
        set { speechPreferences.narratesFootnotes = newValue }
    }
    var silenceTrim: SilenceTrim {
        get { speechPreferences.silenceTrim }
        set { speechPreferences.silenceTrim = newValue }
    }

    var allowAutomaticSystemVoiceFallback: Bool {
        get { speechPreferences.allowAutomaticSystemVoiceFallback }
        set { speechPreferences.allowAutomaticSystemVoiceFallback = newValue }
    }
    var allowOnlineAudioFallback: Bool {
        get { speechPreferences.allowOnlineAudioFallback }
        set { speechPreferences.allowOnlineAudioFallback = newValue }
    }
    var languageModelChoices: [String: TtsSelection] { speechPreferences.languageModelChoices }
    func selectLanguageModel(_ selection: TtsSelection, for language: String) {
        speechPreferences.selectLanguageModel(selection, for: language)
    }
    func clearLanguageModel(for language: String) { speechPreferences.clearLanguageModel(for: language) }
    var bookVoices: BookVoiceOverrides { speechPreferences.bookVoices }
    func selectPrimaryNarration(_ selection: TtsSelection) { speechPreferences.selectPrimaryNarration(selection) }
    func selectSecondaryNarration(_ selection: TtsSelection?) { speechPreferences.selectSecondaryNarration(selection) }

    var primaryEngine: String { speechPreferences.primaryEngine }
    var selectableSecondaryEngines: [String] { speechPreferences.selectableSecondaryEngines }
    var ttsPreferences: TtsPreferences { speechPreferences.ttsPreferences }
    var configuredNarrationSelections: [TtsSelection] { speechPreferences.configuredNarrationSelections }
}
