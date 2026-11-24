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
    /// 1-based position in the Rust catalog's shared popularity list; absent for languages outside it.
    var popularityRank: Int? = nil
    enum CodingKeys: String, CodingKey {
        case tag
        case modelCount = "model_count"
        case popularityRank = "popularity_rank"
    }
}

/// Result of `converter_book_language_json_v1`: the language before any job exists.
struct BookLanguageAnalysis: Decodable, Sendable, Equatable {
    let declared: String?
    let confirmed: String?
    let languages: [String]
    let samplesExamined: Int
    let inconclusiveSamples: Int
    /// The whole-book profile (additive; absent from an older library).
    var profile: BookLanguageProfile? = nil
    enum CodingKeys: String, CodingKey {
        case declared, confirmed, languages, profile
        case samplesExamined = "samples_examined"
        case inconclusiveSamples = "inconclusive_samples"
    }
}

/// `profile` of `converter_book_language_json_v1` (CONTEXT.md, "Book language profile"): the languages the book
/// really contains; quotations in other languages are only listed as `incidental`.
struct BookLanguageProfile: Decodable, Sendable, Equatable {
    enum Kind: String, Decodable, Sendable { case monolingual, bilingual, multilingual }
    struct Entry: Decodable, Sendable, Equatable {
        let language: String
        let chars: Int
        let fraction: Double
        let longestSectionChars: Int
        enum CodingKeys: String, CodingKey {
            case language, chars, fraction
            case longestSectionChars = "longest_section_chars"
        }
    }
    let kind: Kind
    let primary: String
    let languages: [Entry]
    let incidental: [String]
    enum CodingKeys: String, CodingKey {
        case kind = "class"
        case primary, languages, incidental
    }
}
