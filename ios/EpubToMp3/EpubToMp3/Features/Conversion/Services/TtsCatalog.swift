import Foundation

/// Shared descriptors select models without encoding their IDs in client logic.
struct TtsCatalog: Sendable {
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
            allowOnlineFallback: preferences.allowOnlineFallback, policyVersion: preferences.policyVersion,
            footnoteNarration: preferences.footnoteNarration)
    }

    struct Model: Sendable {
        let id: String
        let engine: String
        let runtime: String?
        let revision: String
        let languages: [String]
        let platforms: [String]
        let runtimeAvailable: Bool?
        let artifacts: [Artifact]?

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
        let snapshot = try JSONDecoder().decode(CatalogSnapshot.self, from: json)
        guard snapshot.schema_version == 3 else {
            throw EmbeddedConverterError.artifactInvalid("Unsupported TTS catalog version")
        }
        return Self(version: 3, models: snapshot.entries.map { entry in
            Model(id: entry.identity.modelID, engine: entry.identity.provider,
                  runtime: entry.identity.runtime, revision: entry.identity.modelRevision ?? "",
                  languages: entry.language_evidence.routingTags,
                  platforms: entry.compatibility.platforms,
                  runtimeAvailable: entry.compatibility.runtime_available,
                  artifacts: entry.distribution.artifacts)
        }, providers: snapshot.providers)
    }

    private struct CatalogSnapshot: Decodable {
        let schema_version: UInt32
        let providers: [Provider]?
        let entries: [Entry]
    }

    private struct Entry: Decodable {
        let identity: SpeechModelSnapshot.Identity
        let language_evidence: SpeechModelSnapshot.LanguageEvidence
        let compatibility: Support
        let distribution: Distribution
    }

    private struct Support: Decodable {
        let platforms: [String]
        let runtime_available: Bool
    }

    private struct Distribution: Decodable {
        let artifacts: [Artifact]
    }
}
