import Foundation

/// Reads and migrates the saved speech policy without reinterpreting explicit opt-outs.
struct SpeechPreferenceMigration {
    var primary: AudioEnginePreference = .piper
    var secondary: AudioEnginePreference?
    var allowOnlineFallback = false

    init(defaults: UserDefaults) {
        primary = AudioEnginePreference(
            rawValue: defaults.string(forKey: AppSettings.audioEngineKey) ?? "piper"
        ) ?? .piper
        let storedSecondaryAudioEngine = defaults.string(forKey: "secondaryAudioEngine")
            .flatMap(AudioEnginePreference.init(rawValue:))
        let storedOnlineFallbackConsent = defaults.bool(forKey: "allowOnlineAudioFallback")
        // A missing secondary in old settings may be an explicit no-fallback
        // choice. Only an entirely unconfigured speech policy adopts defaults.
        let hasSavedSpeechPolicy = [AppSettings.audioEngineKey, "secondaryAudioEngine",
                                    "allowOnlineAudioFallback", "ttsPreferencesVersion"]
            .contains { defaults.object(forKey: $0) != nil }
        secondary = hasSavedSpeechPolicy ? storedSecondaryAudioEngine : .system
        if !hasSavedSpeechPolicy {
            defaults.set("piper", forKey: AppSettings.audioEngineKey)
            defaults.set("system", forKey: "secondaryAudioEngine")
            defaults.set(2, forKey: "ttsPreferencesVersion")
        }
        allowOnlineFallback = storedOnlineFallbackConsent
        if storedSecondaryAudioEngine == primary
            || (!storedOnlineFallbackConsent && storedSecondaryAudioEngine == .edge) {
            secondary = nil
            defaults.removeObject(forKey: "secondaryAudioEngine")
        }
    }
}
