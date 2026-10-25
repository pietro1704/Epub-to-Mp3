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
        let compatibility: Compatibility
        let installation: Installation
        let readiness: Readiness
        let selection: SelectionAvailability

        enum CodingKeys: String, CodingKey {
            case identity, presentation, distribution, compatibility, installation, readiness, selection
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

/// Serializes access to one converter binding and keeps filesystem inspection off MainActor.
actor SpeechModelLibraryClient {
    nonisolated let initialSnapshot: SpeechModelSnapshot?

    private let adapter: ConverterFFIAdapter?
    private let target: SpeechModelLibraryTarget
    private let snapshotOverride: (() throws -> SpeechModelSnapshot)?
    private let installOverride: ((String, String) throws -> URL)?

    init(
        target: SpeechModelLibraryTarget = .current(),
        adapter: ConverterFFIAdapter = ConverterFFIAdapter()
    ) {
        self.target = target
        self.adapter = adapter
        self.snapshotOverride = nil
        self.installOverride = nil
        self.initialSnapshot = nil
    }

    init(
        initialSnapshot: SpeechModelSnapshot,
        loadSnapshot: (() throws -> SpeechModelSnapshot)? = nil,
        install: ((String, String) throws -> URL)? = nil,
        target: SpeechModelLibraryTarget = .current()
    ) {
        self.target = target
        self.adapter = nil
        self.snapshotOverride = loadSnapshot ?? { initialSnapshot }
        self.installOverride = install
        self.initialSnapshot = initialSnapshot
    }

    func snapshot() throws -> SpeechModelSnapshot {
        if let snapshotOverride { return try snapshotOverride() }
        guard let adapter else { throw EmbeddedConverterError.artifactUnavailable }
        return try adapter.speechModelSnapshot(target: target)
    }

    func install(modelID: String) throws -> URL {
        if let installOverride { return try installOverride(modelID, target.modelsRoot.path) }
        guard let adapter else { throw EmbeddedConverterError.artifactUnavailable }
        return try adapter.installTtsModelFromCatalog(modelID: modelID, root: target.modelsRoot.path)
    }
}

/// Presentation helpers never participate in persisted model or voice identity.
struct SpeechModelLibraryViewState: Sendable {
    let snapshot: SpeechModelSnapshot?

    static let empty = Self(snapshot: nil)

    var defaultEntry: SpeechModelSnapshot.Entry? {
        guard let identity = snapshot?.defaultSelection.modelID else { return nil }
        return snapshot?.entries.first { $0.identity.modelID == identity }
    }

    func entry(for selection: TtsSelection) -> SpeechModelSnapshot.Entry? {
        guard let modelID = selection.modelID else { return nil }
        return snapshot?.entries.first {
            $0.identity.modelID == modelID && $0.identity.provider == selection.engine
        }
    }

    func displayName(for selection: TtsSelection) -> String {
        entry(for: selection).map(displayName(for:)) ?? fallbackName(for: selection)
    }

    func displayName(for entry: SpeechModelSnapshot.Entry) -> String {
        var fields = [entry.presentation.modelName]
        if let tag = entry.languageEvidence.exactTags.first?.tag {
            fields.append(Locale.current.localizedString(forIdentifier: tag) ?? tag)
        }
        switch entry.presentation.quality {
        case .low: fields.append(L10n.string("settings.modelQuality.low"))
        case .medium: fields.append(L10n.string("settings.modelQuality.medium"))
        case .unspecified: break
        }
        return fields.joined(separator: " · ")
    }

    func status(for entry: SpeechModelSnapshot.Entry) -> String {
        let installation: String
        switch entry.installation.state {
        case .notInspected: installation = L10n.string("settings.modelState.notInspected")
        case .notApplicable: installation = L10n.string("settings.modelState.notInstallable")
        case .missing: installation = L10n.string("settings.modelState.notInstalled")
        case .corrupted: installation = L10n.string("settings.modelState.corrupted")
        case .staleRevision: installation = L10n.string("settings.modelState.updateRequired")
        case .installed: installation = L10n.string("settings.modelState.installed")
        }
        guard entry.installation.state == .installed else { return installation }
        let readiness: String
        switch entry.readiness.state {
        case .ready: readiness = L10n.string("settings.modelState.ready")
        case .unavailable: readiness = L10n.string("settings.modelState.unavailable")
        case .notInspected: readiness = L10n.string("settings.modelState.readinessNotInspected")
        case .notApplicable: return installation
        }
        return "\(installation) · \(readiness)"
    }

    func installTitle(for entry: SpeechModelSnapshot.Entry) -> String {
        let key = entry.installation.state == .installed
            ? "settings.modelInstalled" : "settings.modelInstall"
        return L10n.string(key, displayName(for: entry))
    }

    var selectableChoices: [(selection: TtsSelection, title: String)] {
        snapshot?.entries.flatMap { entry -> [(TtsSelection, String)] in
            guard entry.selection.selectable, let runtime = entry.identity.runtime else { return [] }
            let voices: [SpeechModelSnapshot.VoiceChoice?]
            if entry.presentation.voiceChoices.isEmpty {
                voices = [nil]
            } else if entry.presentation.voiceChoices.count == 1 {
                voices = [entry.presentation.voiceChoices[0]]
            } else {
                voices = entry.presentation.voiceChoices.map(Optional.some).filter { $0?.voiceID != nil }
            }
            return voices.map { voice in
                let selection = TtsSelection(
                    engine: entry.identity.provider,
                    modelID: entry.identity.modelID,
                    voice: voice?.voiceID,
                    session: TtsSessionSelection(
                        provider: entry.identity.provider,
                        runtime: runtime,
                        modelID: entry.identity.modelID,
                        modelRevision: entry.identity.modelRevision,
                        voice: voice?.voiceID
                    )
                )
                let modelName = displayName(for: entry)
                let title = voice.flatMap { entry.presentation.voiceChoices.count > 1 ? $0.name : nil }
                    .map { "\(modelName) · \($0)" } ?? modelName
                return (selection, title)
            }
        } ?? []
    }

    private func fallbackName(for selection: TtsSelection) -> String {
        AudioEnginePreference(rawValue: selection.engine)?.displayName ?? selection.engine
    }
}
