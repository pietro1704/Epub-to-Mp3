import Foundation

enum AudioEnginePreference: String, CaseIterable, Identifiable {
    case edge
    case piper
    case system

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .edge: return "Edge"
        case .piper: return "Piper"
        case .system: return L10n.string("settings.systemTts")
        }
    }

    static var supportedPreferences: [AudioEnginePreference] {
        [.piper, .system, .edge]
    }
}

/// Immutable selections transported to the shared Rust policy resolver.
struct TtsSelection: Codable, Sendable, Equatable {
    var engine: String
    var modelID: String?
    var voice: String?
    var session: TtsSessionSelection? = nil
    enum CodingKeys: String, CodingKey { case engine, voice, session; case modelID = "model_id" }
    static func selected(_ engine: AudioEnginePreference) -> Self {
        Self(engine: engine.rawValue, modelID: engine == .piper ? "pt_BR-faber-medium" : nil,
             voice: nil)
    }
    func representsSameRequest(as other: Self) -> Bool {
        guard engine == other.engine, modelID == other.modelID, voice == other.voice else { return false }
        guard let session, let otherSession = other.session else {
            return (session?.options.isEmpty ?? true) && (other.session?.options.isEmpty ?? true)
        }
        return session.runtime == otherSession.runtime && session.options == otherSession.options
    }
}

struct TtsSessionSelection: Codable, Sendable, Equatable {
    var version: UInt32 = 2
    var provider: String
    var runtime: String
    var modelID: String?
    var modelRevision: String?
    var voice: String?
    var options: [String: String] = [:]
    enum CodingKeys: String, CodingKey {
        case version, provider, runtime, voice, options
        case modelID = "model_id", modelRevision = "model_revision"
    }
}

struct TtsPreferences: Codable, Sendable, Equatable {
    var primary: TtsSelection
    var secondary: TtsSelection?
    var allowOnlineFallback: Bool
    /// Absent in legacy job snapshots, which must retain their original policy.
    var policyVersion: UInt32? = nil
    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case allowOnlineFallback = "allow_online_fallback"
        case policyVersion = "policy_version"
    }
}

extension JobSnapshot {
    /// Present the resolved voice names; installed identifiers remain in diagnostic state.
    var activeVoiceDisplayName: String? {
        guard let voice, !voice.isEmpty else { return nil }
        return SpeechModelPresentationStore.shared.activeVoices(voice, engine: engine)
    }
}
