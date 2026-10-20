import Foundation

enum AudioEnginePreference: String, CaseIterable, Identifiable {
    case edge
    case piper
    case system

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .edge: return "Edge"
        case .piper: return "Faber medium"
        case .system: return L10n.string("settings.systemVoice")
        }
    }

    static var supportedPreferences: [AudioEnginePreference] {
        [.piper, .edge, .system]
    }
}

/// Immutable selections transported to the shared Rust policy resolver.
struct TtsSelection: Codable, Sendable, Equatable {
    var engine: String
    var modelID: String?
    var voice: String?
    enum CodingKeys: String, CodingKey { case engine, voice; case modelID = "model_id" }
    static func selected(_ engine: AudioEnginePreference) -> Self {
        Self(engine: engine.rawValue, modelID: engine == .piper ? "pt_BR-faber-medium" : nil,
             voice: nil)
    }
}

struct TtsPreferences: Codable, Sendable, Equatable {
    var primary: TtsSelection
    var secondary: TtsSelection?
    var allowOnlineFallback: Bool
    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case allowOnlineFallback = "allow_online_fallback"
    }
}
