import Foundation

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
    /// How Rust narrates footnotes; nil is the Rust default (`inline`) and is not sent.
    var footnoteNarration: FootnoteNarration? = nil
    /// How much silence Rust trims from new audio; nil is the Rust default (`light`) and is not sent.
    var silenceTrim: SilenceTrim? = nil
    enum CodingKeys: String, CodingKey {
        case primary, secondary
        case allowOnlineFallback = "allow_online_fallback"
        case policyVersion = "policy_version"
        case footnoteNarration = "footnote_narration"
        case silenceTrim = "silence_trim"
    }
}

/// Rust `FootnoteNarration`: `inline` reads each note at its reference, `skip` leaves the notes out.
enum FootnoteNarration: String, Codable, Sendable, Equatable {
    case inline, skip
}

/// Rust `SilenceTrim`, in the order the levels are offered. Rust does the trimming.
enum SilenceTrim: String, Codable, Sendable, Equatable, CaseIterable {
    case off, light, medium, strong

    /// What `TtsPreferences` carries: `light` is left out so saved cache identities stay valid.
    var sentValue: Self? { self == .light ? nil : self }
}
