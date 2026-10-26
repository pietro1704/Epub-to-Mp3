import Foundation

/// Immutable Apple projection of the Rust-owned speech-model snapshot.
struct SpeechModelSnapshot: Decodable, Sendable {
    let schemaVersion: UInt32
    let generatedFromCatalogRevision: String
    let defaultSelection: TtsSessionSelection
    let entries: [Entry]

    enum CodingKeys: String, CodingKey {
        case entries
        case schemaVersion = "schema_version"
        case generatedFromCatalogRevision = "generated_from_catalog_revision"
        case defaultSelection = "default_selection"
    }

    struct Entry: Decodable, Sendable {
        let identity: Identity
        let presentation: Presentation
        let languageEvidence: LanguageEvidence
        let distribution: Distribution
        let licence: Licence
        let compatibility: Compatibility
        let installation: Installation
        let readiness: Readiness
        let selection: SelectionAvailability

        enum CodingKeys: String, CodingKey {
            case identity, presentation, distribution, licence, compatibility, installation, readiness, selection
            case languageEvidence = "language_evidence"
        }
    }

    struct Identity: Decodable, Sendable {
        let provider: String
        let runtime: String?
        let modelID: String
        let modelRevision: String?

        enum CodingKeys: String, CodingKey {
            case provider, runtime
            case modelID = "model_id"
            case modelRevision = "model_revision"
        }
    }

    struct Presentation: Decodable, Sendable {
        let modelName: String
        let familyName: String
        let quality: Quality
        let voiceChoices: [VoiceChoice]

        enum CodingKeys: String, CodingKey {
            case quality
            case modelName = "model_name"
            case familyName = "family_name"
            case voiceChoices = "voice_choices"
        }
    }

    enum Quality: String, Decodable, Sendable {
        case low, medium, unspecified
    }

    struct VoiceChoice: Decodable, Sendable {
        let voiceID: String?
        let name: String

        enum CodingKeys: String, CodingKey {
            case name
            case voiceID = "voice_id"
        }
    }

    struct LanguageEvidence: Decodable, Sendable {
        let routingTags: [String]
        let exactTags: [ExactLanguage]

        enum CodingKeys: String, CodingKey {
            case routingTags = "routing_tags"
            case exactTags = "exact_tags"
        }
    }

    struct ExactLanguage: Decodable, Sendable {
        let tag: String
        let frontend: String?
        let validation: String
    }

    struct Distribution: Decodable, Sendable {
        let installable: Bool
        let downloadBytes: UInt64?
        let installedBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case installable
            case downloadBytes = "download_bytes"
            case installedBytes = "installed_bytes"
        }
    }

    struct Licence: Decodable, Sendable {
        let id: String?
        let category: String
        let evidenceURL: URL?
        let termsFingerprint: String?
        let requiresAcceptance: Bool
        let validation: String

        enum CodingKeys: String, CodingKey {
            case id, category, validation
            case evidenceURL = "evidence_url"
            case termsFingerprint = "terms_fingerprint"
            case requiresAcceptance = "requires_acceptance"
        }
    }

    struct Compatibility: Decodable, Sendable {
        let compatible: Bool
        let reasons: [String]
    }

    struct Installation: Decodable, Sendable {
        let state: InstallationState
        let verifiedRevision: String?
        let installedBytes: UInt64?

        enum CodingKeys: String, CodingKey {
            case state
            case verifiedRevision = "verified_revision"
            case installedBytes = "installed_bytes"
        }
    }

    enum InstallationState: String, Decodable, Sendable {
        case notInspected = "not_inspected"
        case notApplicable = "not_applicable"
        case missing, corrupted
        case staleRevision = "stale_revision"
        case installed
    }

    struct Readiness: Decodable, Sendable {
        let state: ReadinessState
        let activeRuntimeRevision: String?
        let failure: String?

        enum CodingKeys: String, CodingKey {
            case state, failure
            case activeRuntimeRevision = "active_runtime_revision"
        }
    }

    enum ReadinessState: String, Decodable, Sendable {
        case notInspected = "not_inspected"
        case notApplicable = "not_applicable"
        case ready, unavailable
    }

    struct SelectionAvailability: Decodable, Sendable {
        let selectable: Bool
        let reasons: [String]
    }

    static func decode(_ data: Data) throws -> Self {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.schemaVersion == 3 else {
            throw EmbeddedConverterError.artifactInvalid("Unsupported speech model snapshot version")
        }
        return snapshot
    }
}

struct SpeechModelLibraryTarget: Sendable {
    let language: String
    let platform: String
    let androidAPI: UInt32
    let architecture: String
    let osVersion: String
    let modelsRoot: URL

    static func current(fileManager: FileManager = .default) -> Self {
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        #if arch(x86_64)
        let architecture = "x86_64"
        #elseif arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unknown"
        #endif
        let root = LocalSpeechModelReadiness.ttsModelsRoot(fileManager: fileManager, create: false)
            ?? fileManager.temporaryDirectory.appendingPathComponent("EpubToMp3/TTSModels", isDirectory: true)
        return Self(
            language: Locale.preferredLanguages.first ?? "en",
            platform: platform,
            androidAPI: 0,
            architecture: architecture,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelsRoot: root
        )
    }
}
