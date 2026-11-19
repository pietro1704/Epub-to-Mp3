import Foundation

/// The speech surface of `AppSettings`, kept for its callers; the values and
/// their rules belong to `SpeechPreferences`.
extension AppSettings {
    var primaryTtsSelection: TtsSelection { speechPreferences.primaryTtsSelection }
    var secondaryTtsSelection: TtsSelection? { speechPreferences.secondaryTtsSelection }
    var allowAutomaticSystemVoiceFallback: Bool {
        get { speechPreferences.allowAutomaticSystemVoiceFallback }
        set { speechPreferences.allowAutomaticSystemVoiceFallback = newValue }
    }
    var allowOnlineAudioFallback: Bool {
        get { speechPreferences.allowOnlineAudioFallback }
        set { speechPreferences.allowOnlineAudioFallback = newValue }
    }
    func selectPrimaryNarration(_ selection: TtsSelection) { speechPreferences.selectPrimaryNarration(selection) }
    func selectSecondaryNarration(_ selection: TtsSelection?) { speechPreferences.selectSecondaryNarration(selection) }

    var primaryEngine: String { speechPreferences.primaryEngine }
    var selectableSecondaryEngines: [String] { speechPreferences.selectableSecondaryEngines }
    var ttsPreferences: TtsPreferences { speechPreferences.ttsPreferences }
    var configuredNarrationSelections: [TtsSelection] { speechPreferences.configuredNarrationSelections }

    var conversionOptions: ConversionOptions {
        var options = ConversionOptions.selectedEngine(primaryEngine, modelsRoot: LocalSpeechModelReadiness.ttsModelsRoot())
        options.ttsPreferences = ttsPreferences
        if let catalog = try? ConverterFFIAdapter().ttsCatalog() {
            #if os(macOS)
            options.ttsPreferences = catalog.capture(ttsPreferences, target: "macos")
            #else
            options.ttsPreferences = catalog.capture(ttsPreferences, target: "ios")
            #endif
        }
        options.modelsRoot = LocalSpeechModelReadiness.ttsModelsRoot()?.path
        options.espeakDataDirectory = Bundle.main.resourceURL?.path
        return options
    }
}
