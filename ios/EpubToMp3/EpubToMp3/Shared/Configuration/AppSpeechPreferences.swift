import Foundation

extension AppSettings {
    /// Engine of the primary voice; it also names the reader's saved local audio.
    var primaryEngine: String { primaryTtsSelection.engine }
    /// Engine-default secondaries the user may pick for the current primary.
    var selectableSecondaryEngines: [String] {
        TtsSelection.selectableEngines.filter {
            TtsSelection.engineDefault($0).canBeSecondary(to: primaryTtsSelection,
                                                          allowOnlineFallback: allowOnlineAudioFallback)
        }
    }
    var ttsPreferences: TtsPreferences {
        let secondary = secondaryTtsSelection.flatMap {
            $0.isAllowedAsFallback(allowOnlineFallback: allowOnlineAudioFallback) ? $0 : nil
        }
        return TtsPreferences(primary: primaryTtsSelection,
                              secondary: secondary,
                              allowOnlineFallback: allowOnlineAudioFallback,
                              policyVersion: allowAutomaticSystemVoiceFallback ? 2 : 3)
    }
    var configuredNarrationSelections: [TtsSelection] {
        [ttsPreferences.primary, ttsPreferences.secondary].compactMap { $0 }
    }
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
