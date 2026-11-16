#if os(iOS)
import AVFoundation
import Foundation

/// The Apple listening UI asks before silently falling back when no local model
/// can narrate the book. Rust still supplies metadata, compatibility and readiness.
enum TtsMissingVoicePreflight {
    static func requiresCheck(options: ConversionOptions?) -> Bool {
        (options?.ttsPreferences?.primary.engine ?? options?.engine ?? "piper") == "piper"
    }

    static func installedSystemVoices() -> [InstalledSpeechVoicePolicy.Voice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            InstalledSpeechVoicePolicy.Voice(identifier: $0.identifier, name: $0.name, language: $0.language,
                                             isCompact: $0.quality == .default)
        }
    }

    /// Policy 3 continues only through explicitly configured voices, so a system
    /// secondary chosen in Settings or in the recovery alert is not a silent
    /// fallback. Automatic system recovery (policy 2) still asks first.
    static func acceptsExplicitSystemVoice(options: ConversionOptions?, language: String,
                                           voices: [InstalledSpeechVoicePolicy.Voice]) -> Bool {
        guard let preferences = options?.ttsPreferences, preferences.policyVersion == 3,
              preferences.secondary?.engine == "system" else { return false }
        return InstalledSpeechVoicePolicy.select(language: language, voices: voices) != nil
    }

    static func validate(metadata: Data, options: ConversionOptions?,
                         client: SpeechModelLibraryClient = .shared,
                         systemVoices: () -> [InstalledSpeechVoicePolicy.Voice] = installedSystemVoices) async throws {
        guard requiresCheck(options: options),
              let fields = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let language = options?.language ?? fields["language"] as? String,
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try Task.checkCancellation()
        let snapshot = try await client.recoverySnapshot(language: language)
        try Task.checkCancellation()
        guard TtsRecoveryCandidate.available(in: snapshot, excluding: "").isEmpty else { return }
        if acceptsExplicitSystemVoice(options: options, language: language, voices: systemVoices()) { return }
        let modelID = options?.ttsPreferences?.primary.modelID ?? options?.modelID ?? "piper"
        let context = try JSONSerialization.data(withJSONObject: ["language": language, "model_id": modelID], options: .sortedKeys)
        throw EmbeddedConverterError.conversionFailed(
            "No installed voice for book language [[tts_language_mismatch_v1]]"
                + String(decoding: context, as: UTF8.self) + "[[/tts_language_mismatch_v1]]")
    }
}
#endif
