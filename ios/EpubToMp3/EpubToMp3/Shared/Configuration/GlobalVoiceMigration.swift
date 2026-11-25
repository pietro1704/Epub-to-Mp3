import Foundation

/// One-shot migration for the retired global "Voice model" and "Reserve voice" menus.
///
/// The voice is now chosen per language (and per book), so a saved primary other than
/// the default Piper voice would stay active with no control to change it:
///
/// - Another Piper model becomes the choice of its own language.
/// - A system or Edge primary becomes the choice of the device's languages and of the
///   library's analyzed books.
///
/// An existing choice always wins, and the primary then returns to the default Piper
/// voice. The saved reserve is kept; one that equals the new primary swaps with the
/// old primary, so the pair of voices survives. It has its own version key so it also
/// runs on stores `SpeechPreferenceMigration` already completed.
enum GlobalVoiceMigration {
    static let versionKey = "globalVoiceMenuMigration.version"
    static let currentVersion = 1

    static func runIfNeeded(_ preferences: SpeechPreferences, defaults: UserDefaults, preferredLanguages: [String]) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }
        defer { defaults.set(currentVersion, forKey: versionKey) }
        let primary = preferences.primaryTtsSelection
        let languages: [String]
        if primary.isPiper {
            guard let modelID = primary.modelID, modelID != TtsSelection.defaultPiperModelID else { return }
            languages = [modelID]
        } else {
            languages = preferredLanguages + BookLanguageSummaries(defaults: defaults)
                .languages(corrections: BookLanguageCorrections(defaults: defaults))
        }
        for language in languages where preferences.languageModelChoices[SpeechPreferences.languageKey(language)] == nil {
            preferences.selectLanguageModel(primary, for: language)
        }
        let reserve = preferences.secondaryTtsSelection
        preferences.selectPrimaryNarration(.defaultPiper)
        if reserve != nil, preferences.secondaryTtsSelection == nil {
            preferences.selectSecondaryNarration(primary)
        }
    }
}
