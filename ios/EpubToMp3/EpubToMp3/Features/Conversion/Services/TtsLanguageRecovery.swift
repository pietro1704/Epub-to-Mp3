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

/// A download suggestion is presentation over Rust's compatibility decision.
enum TtsMissingVoicePolicy {
    static func recommended(in snapshot: SpeechModelSnapshot) -> SpeechModelSnapshot.Entry? {
        snapshot.entries.filter {
            $0.identity.provider == "piper" && $0.distribution.installable
                && $0.compatibility.compatible && $0.installation.state != .installed
                && $0.licence.validation != "rejected"
        }.sorted {
            let firstDefault = $0.identity.modelID == snapshot.defaultSelection.modelID
            let secondDefault = $1.identity.modelID == snapshot.defaultSelection.modelID
            if firstDefault != secondDefault { return firstDefault }
            let firstMedium = $0.presentation.quality == .medium
            let secondMedium = $1.presentation.quality == .medium
            if firstMedium != secondMedium { return firstMedium }
            let firstBytes = $0.distribution.downloadBytes ?? UInt64.max
            let secondBytes = $1.distribution.downloadBytes ?? UInt64.max
            if firstBytes != secondBytes { return firstBytes < secondBytes }
            return $0.identity.modelID < $1.identity.modelID
        }.first
    }
}
