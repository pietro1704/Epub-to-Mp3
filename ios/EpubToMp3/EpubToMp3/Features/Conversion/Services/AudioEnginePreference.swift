import Foundation

/// Immutable selections transported to the shared Rust policy resolver.
struct TtsSelection: Codable, Sendable, Equatable {
    var engine: String
    var modelID: String?
    var voice: String?
    var session: TtsSessionSelection? = nil
    enum CodingKeys: String, CodingKey { case engine, voice, session; case modelID = "model_id" }
    func representsSameRequest(as other: Self) -> Bool {
        guard engine == other.engine, modelID == other.modelID, voice == other.voice else { return false }
        guard let session, let otherSession = other.session else {
            return (session?.options.isEmpty ?? true) && (other.session?.options.isEmpty ?? true)
        }
        return session.runtime == otherSession.runtime && session.options == otherSession.options
    }
}

/// Engine identities and the selection rules every voice control shares.
///
/// `engine` stays a string because it is the Rust transport identity; these
/// helpers are the only place the app spells the engine names and the default
/// Piper model.
extension TtsSelection {
    static let piperEngine = "piper"
    static let systemEngine = "system"
    static let edgeEngine = "edge"
    /// The Piper model narrating when no other Piper model was chosen.
    static let defaultPiperModelID = "pt_BR-faber-medium"
    /// Engines offered by the voice menus, in menu order.
    static let selectableEngines = [piperEngine, systemEngine, edgeEngine]

    /// Default primary narration: Piper with the Faber model.
    static var defaultPiper: Self { engineDefault(piperEngine) }
    /// Installed system speech with its default voice.
    static var systemDefault: Self { engineDefault(systemEngine) }
    /// Online Edge speech with its default voice.
    static var edgeDefault: Self { engineDefault(edgeEngine) }

    /// The model an engine uses when the request names none: Faber for Piper.
    static func defaultModelID(forEngine engine: String) -> String? {
        engine == piperEngine ? defaultPiperModelID : nil
    }

    /// An engine-level request without a chosen model.
    static func engineDefault(_ engine: String, voice: String? = nil) -> Self {
        Self(engine: engine, modelID: defaultModelID(forEngine: engine), voice: voice)
    }

    /// Localized name of a selectable engine; `nil` for any other identity.
    static func displayName(forEngine engine: String) -> String? {
        switch engine {
        case piperEngine: return "Piper"
        case systemEngine: return L10n.string("settings.systemTts")
        case edgeEngine: return "Edge"
        default: return nil
        }
    }

    var isPiper: Bool { engine == Self.piperEngine }
    var isSystem: Bool { engine == Self.systemEngine }
    var isEdge: Bool { engine == Self.edgeEngine }

    /// Online Edge speech may only be used as a fallback after explicit consent.
    func isAllowedAsFallback(allowOnlineFallback: Bool) -> Bool {
        !isEdge || allowOnlineFallback
    }

    /// A secondary voice must be a different request than the primary, and
    /// Edge needs the online-fallback consent.
    func canBeSecondary(to primary: Self, allowOnlineFallback: Bool) -> Bool {
        !representsSameRequest(as: primary) && isAllowedAsFallback(allowOnlineFallback: allowOnlineFallback)
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
