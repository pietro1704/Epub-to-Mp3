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
    var modelsRoot: String?
    var modelID: String?
    var modelPath: String?
    var modelConfigPath: String?

    init(
        schemaVersion: UInt32 = 1,
        engine: String? = nil,
        voice: String? = nil,
        language: String? = nil,
        clearCache: Bool = false,
        forceReprocess: Bool = false,
        maxPerformance: Bool = false,
        modelsRoot: String? = nil,
        modelID: String? = nil,
        modelPath: String? = nil,
        modelConfigPath: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.engine = engine
        self.voice = voice
        self.language = language
        self.clearCache = clearCache
        self.forceReprocess = forceReprocess
        self.maxPerformance = maxPerformance
        self.modelsRoot = modelsRoot
        self.modelID = modelID
        self.modelPath = modelPath
        self.modelConfigPath = modelConfigPath
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case engine, voice, language
        case clearCache = "clear_cache"
        case forceReprocess = "force_reprocess"
        case maxPerformance = "max_performance"
        case modelsRoot = "models_root"
        case modelID = "model_id"
        case modelPath = "model_path"
        case modelConfigPath = "model_config_path"
    }

    /// Foundation-only encoding for both the adapter and native contract tests.
    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
