import Foundation

extension AppSettings {
    var selectableSecondaryAudioEngines: [AudioEnginePreference] {
        AudioEnginePreference.supportedPreferences.filter {
            $0 != audioEngine && ($0 != .edge || allowOnlineAudioFallback)
        }
    }
    var ttsPreferences: TtsPreferences {
        let secondary = secondaryTtsSelection ?? secondaryAudioEngine.flatMap { engine -> TtsSelection? in
            guard engine != .edge || allowOnlineAudioFallback else { return nil }
            return .selected(engine)
        }
        return TtsPreferences(primary: primaryTtsSelection ?? .selected(audioEngine),
                              secondary: secondary,
                              allowOnlineFallback: allowOnlineAudioFallback,
                              policyVersion: 2)
    }
    var configuredNarrationSelections: [TtsSelection] {
        [ttsPreferences.primary, ttsPreferences.secondary].compactMap { $0 }
    }
    var primaryNarrationDisplayName: String {
        let selection = ttsPreferences.primary
        return SpeechModelPresentationStore.shared.displayName(
            engine: selection.engine, modelID: selection.modelID, voice: selection.voice
        ) ?? audioEngine.displayName
    }
    var secondaryNarrationDisplayName: String {
        guard let selection = ttsPreferences.secondary else { return L10n.string("settings.noSecondary") }
        return SpeechModelPresentationStore.shared.displayName(
            engine: selection.engine, modelID: selection.modelID, voice: selection.voice
        ) ?? L10n.string("settings.noSecondary")
    }
    func selectPrimaryNarration(_ selection: TtsSelection) {
        if let engine = AudioEnginePreference(rawValue: selection.engine) { audioEngine = engine }
        primaryTtsSelection = selection
        if secondaryTtsSelection?.representsSameRequest(as: selection) == true { secondaryTtsSelection = nil }
    }
    func selectSecondaryNarration(_ selection: TtsSelection?) {
        secondaryAudioEngine = nil
        secondaryTtsSelection = selection
    }
    var conversionOptions: ConversionOptions {
        var options = ConversionOptions.selectedEngine(audioEngine, modelsRoot: LocalSpeechModelReadiness.ttsModelsRoot())
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
