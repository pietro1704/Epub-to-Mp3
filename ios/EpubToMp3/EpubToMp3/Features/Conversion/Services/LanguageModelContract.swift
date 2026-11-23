import Foundation

/// Apple projection of the Rust contract in `docs/models-by-language-contract.md`.
/// Rust owns the resolution; these types only carry it.

struct LanguageModelResolutionRequest: Encodable, Sendable, Equatable {
    var schemaVersion = 1
    var bookLanguage: String
    var perLanguageChoices: [String: TtsSelection] = [:]
    var primary: TtsSelection?
    var allowOnlineFallback = false
    var allowAutomaticSystemVoiceFallback = true
    var installedModelIDs: [String] = []
    var systemVoices: [String] = []
    /// The Rust `ModelPlatform` name (`Macos`, `Ios`, `Android`, ...).
    var platform: String
    var androidAPI: UInt32?

    enum CodingKeys: String, CodingKey {
        case primary, platform
        case schemaVersion = "schema_version"
        case bookLanguage = "book_language"
        case perLanguageChoices = "per_language_choices"
        case allowOnlineFallback = "allow_online_fallback"
        case allowAutomaticSystemVoiceFallback = "allow_automatic_system_voice_fallback"
        case installedModelIDs = "installed_model_ids"
        case systemVoices = "system_voices"
        case androidAPI = "android_api"
    }

    static var currentPlatform: String {
        #if os(macOS)
        "Macos"
        #else
        "Ios"
        #endif
    }
}

struct LanguageModelResolution: Decodable, Sendable, Equatable {
    enum Status: String, Decodable, Sendable { case selected, systemFallback = "system_fallback", missingModel = "missing_model" }
    enum Source: String, Decodable, Sendable { case perLanguage = "per_language", primary, automatic, system }

    struct Suggested: Decodable, Sendable, Equatable {
        let modelID: String
        let engine: String
        let downloadBytes: UInt64
        enum CodingKeys: String, CodingKey { case engine; case modelID = "model_id"; case downloadBytes = "download_bytes" }
    }

    struct Missing: Decodable, Sendable, Equatable {
        let language: String
        let suggested: [Suggested]
    }

    let bookLanguage: String
    let status: Status
    let selection: TtsSelection?
    let source: Source?
    let reasons: [String]
    let missing: Missing?

    enum CodingKeys: String, CodingKey {
        case status, selection, source, reasons, missing
        case bookLanguage = "book_language"
    }
}

struct CatalogLanguage: Decodable, Sendable, Equatable {
    let tag: String
    let modelCount: Int
    enum CodingKeys: String, CodingKey { case tag; case modelCount = "model_count" }
}

/// Result of `converter_book_language_json_v1`: the language before any job exists.
struct BookLanguageAnalysis: Decodable, Sendable, Equatable {
    let declared: String?
    let confirmed: String?
    let languages: [String]
    let samplesExamined: Int
    let inconclusiveSamples: Int
    enum CodingKeys: String, CodingKey {
        case declared, confirmed, languages
        case samplesExamined = "samples_examined"
        case inconclusiveSamples = "inconclusive_samples"
    }
}
