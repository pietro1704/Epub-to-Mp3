import Foundation

/// Shared descriptors select models without encoding their IDs in client logic.
struct TtsCatalog: Decodable, Sendable {
    let version: UInt32
    let models: [Model]
    let providers: [Provider]?

    struct Provider: Decodable, Sendable {
        let provider: String
        let runtime: String
        let targets: [String]
    }

    func capture(_ preferences: TtsPreferences, target: String) -> TtsPreferences {
        func selection(_ current: TtsSelection) -> TtsSelection {
            if current.session != nil { return current }
            if let id = current.modelID {
                return models.first(where: { $0.id == id && $0.engine == current.engine })?.selection(voice: current.voice) ?? current
            }
            guard let descriptor = providers?.first(where: { $0.provider == current.engine && $0.targets.contains(target) }) else { return current }
            var captured = current
            captured.session = TtsSessionSelection(provider: descriptor.provider, runtime: descriptor.runtime, modelID: nil, modelRevision: nil, voice: current.voice)
            return captured
        }
        return TtsPreferences(primary: selection(preferences.primary), secondary: preferences.secondary.map(selection),
            allowOnlineFallback: preferences.allowOnlineFallback, policyVersion: preferences.policyVersion)
    }

    struct Model: Decodable, Sendable {
        let id: String
        let engine: String
        let runtime: String?
        let revision: String
        let languages: [String]
        let platforms: [String]
        let runtimeAvailable: Bool?
        let artifacts: [Artifact]?
        enum CodingKeys: String, CodingKey {
            case id, engine, runtime, revision, languages, platforms, artifacts
            case runtimeAvailable = "runtime_available"
        }

        func selection(voice: String? = nil) -> TtsSelection? {
            guard let runtime else { return nil }
            let session = TtsSessionSelection(provider: engine, runtime: runtime,
                modelID: id, modelRevision: revision, voice: voice)
            return TtsSelection(engine: engine, modelID: id, voice: voice, session: session)
        }
    }

    struct Artifact: Decodable, Sendable {
        let name: String
        let sha256: String
    }

    func selections(platform: String) -> [TtsSelection] {
        models.filter { $0.platforms.contains(platform) && $0.runtimeAvailable == true }.compactMap { $0.selection() }
    }

    static func decode(_ json: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: json)
        guard catalog.version == 2 else {
            throw EmbeddedConverterError.artifactInvalid("Unsupported TTS catalog version")
        }
        return catalog
    }
}
