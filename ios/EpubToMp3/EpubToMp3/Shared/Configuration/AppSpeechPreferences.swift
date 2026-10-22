import Foundation

extension AppSettings {
    var selectableSecondaryAudioEngines: [AudioEnginePreference] {
        AudioEnginePreference.supportedPreferences.filter {
            $0 != audioEngine && ($0 != .edge || allowOnlineAudioFallback)
        }
    }
    var ttsPreferences: TtsPreferences {
        let secondary = secondaryAudioEngine.flatMap { engine -> TtsSelection? in
            guard engine != .edge || allowOnlineAudioFallback else { return nil }
            return .selected(engine)
        }
        return TtsPreferences(primary: .selected(audioEngine),
                              secondary: secondary,
                              allowOnlineFallback: allowOnlineAudioFallback,
                              policyVersion: 2)
    }
    var conversionOptions: ConversionOptions {
        var options = ConversionOptions.selectedEngine(audioEngine, modelsRoot: LocalSpeechModelReadiness.ttsModelsRoot())
        options.ttsPreferences = ttsPreferences
        options.modelsRoot = LocalSpeechModelReadiness.ttsModelsRoot()?.path
        options.espeakDataDirectory = Bundle.main.resourceURL?.path
        return options
    }

}
