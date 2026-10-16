import Foundation

/// Configuration transported to Rust; validation and provider selection belong to Rust.
struct ConversionOptions: Codable, Sendable, Equatable {
    let schemaVersion: UInt32
    var ttsPreferences: TtsPreferences? = nil
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
    var espeakDataDirectory: String?

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
        modelConfigPath: String? = nil,
        espeakDataDirectory: String? = nil
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
        self.espeakDataDirectory = espeakDataDirectory
    }

    static func selectedEngine(_ engine: AudioEnginePreference, modelsRoot: URL? = nil) -> ConversionOptions {
        let resolvedEngine = AudioEnginePreference.supportedPreferences.contains(engine) ? engine : .edge
        return ConversionOptions(
            engine: resolvedEngine.rawValue,
            language: nil,
            modelsRoot: resolvedEngine == .piper ? modelsRoot?.path : nil,
            modelID: resolvedEngine == .piper ? "pt_BR-faber-medium" : nil,
            espeakDataDirectory: resolvedEngine == .piper ? Bundle.main.resourceURL?.path : nil,
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ttsPreferences = "tts_preferences"
        case engine, voice, language
        case clearCache = "clear_cache"
        case forceReprocess = "force_reprocess"
        case maxPerformance = "max_performance"
        case modelsRoot = "models_root"
        case modelID = "model_id"
        case modelPath = "model_path"
        case modelConfigPath = "model_config_path"
        case espeakDataDirectory = "espeak_data_directory"
    }

    /// Foundation-only encoding for both the adapter and native contract tests.
    func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
