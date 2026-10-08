import Foundation

/// Configuration transported to Rust; validation and provider selection belong to Rust.
struct ConversionOptions: Codable, Sendable, Equatable {
    let schemaVersion: UInt32
    var engine: String?
    var voice: String?
    var language: String?
    var clearCache: Bool
    var forceReprocess: Bool
    var maxPerformance: Bool

    init(
        schemaVersion: UInt32 = 1,
        engine: String? = nil,
        voice: String? = nil,
        language: String? = nil,
        clearCache: Bool = false,
        forceReprocess: Bool = false,
        maxPerformance: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.voice = voice
        self.language = language
        self.clearCache = clearCache
        self.forceReprocess = forceReprocess
        self.maxPerformance = maxPerformance
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case engine, voice, language
        case clearCache = "clear_cache"
        case forceReprocess = "force_reprocess"
        case maxPerformance = "max_performance"
    }

    /// Foundation-only encoding for both the adapter and native contract tests.
    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
