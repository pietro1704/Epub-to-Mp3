import Foundation

/// Versioned context emitted by Rust; diagnostics may wrap the envelope.
struct TtsLanguageMismatch: Decodable, Equatable, Sendable {
    let language: String
    let modelID: String
    enum CodingKeys: String, CodingKey { case language; case modelID = "model_id" }

    static func decode(_ error: Error) -> Self? {
        guard case .conversionFailed(let reason) = error as? EmbeddedConverterError,
              let start = reason.range(of: "[[tts_language_mismatch_v1]]"),
              let end = reason.range(of: "[[/tts_language_mismatch_v1]]", range: start.upperBound..<reason.endIndex),
              let context = try? JSONDecoder().decode(Self.self, from: Data(reason[start.upperBound..<end.lowerBound].utf8)),
              !context.language.isEmpty, !context.modelID.isEmpty else { return nil }
        return context
    }
}

struct TtsRecoveryCandidate: Equatable, Sendable {
    let name: String
    let selection: TtsSelection

    /// Compatibility, installation and readiness are decided by the Rust snapshot.
    static func available(in snapshot: SpeechModelSnapshot, excluding modelID: String) -> [Self] {
        snapshot.entries.compactMap { entry in
            guard entry.selection.selectable, entry.compatibility.compatible,
                  entry.installation.state == .installed, entry.readiness.state == .ready,
                  entry.identity.provider != "edge", entry.identity.modelID != modelID,
                  let runtime = entry.identity.runtime, let revision = entry.identity.modelRevision else { return nil }
            let identity = entry.identity
            let session = TtsSessionSelection(provider: identity.provider, runtime: runtime,
                modelID: identity.modelID, modelRevision: revision, voice: nil)
            return Self(name: identity.provider == "system" ? L10n.string("settings.systemTts") : entry.presentation.modelName,
                selection: TtsSelection(engine: identity.provider, modelID: identity.modelID, voice: nil, session: session))
        }
    }
}

extension ConversionOptions {
    func recovering(with candidate: TtsRecoveryCandidate, language: String) -> Self {
        var copy = self
        // A compatible second voice serves its own passages; it does not change
        // the book's language or replace the configured primary voice.
        if var preferences = copy.ttsPreferences {
            if preferences.primary != candidate.selection { preferences.secondary = candidate.selection }
            preferences.policyVersion = 3
            preferences.allowOnlineFallback = false
            copy.ttsPreferences = preferences
            return copy
        }
        copy.engine = candidate.selection.engine
        copy.modelID = candidate.selection.modelID
        copy.modelPath = nil
        copy.modelConfigPath = nil
        copy.voice = candidate.selection.voice
        copy.ttsPreferences = TtsPreferences(primary: candidate.selection, secondary: nil, allowOnlineFallback: false, policyVersion: 3)
        return copy
    }
}
