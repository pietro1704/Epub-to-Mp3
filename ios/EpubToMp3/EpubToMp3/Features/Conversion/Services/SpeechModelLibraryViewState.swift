import Foundation

enum SpeechModelInstallationError: LocalizedError, Equatable {
    case duplicate(String)
    case failure(SpeechModelInstallEvent.Failure)
    case incompatible(String)
    case notInstallable(String)
    case termsAcceptanceRequired(String)
    case unknownModel(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case let .duplicate(modelID):
            return "A model installation is already active for \(modelID)"
        case let .failure(failure):
            return failure.message
        case .incompatible:
            return L10n.string("settings.modelInstall.incompatible")
        case .notInstallable:
            return L10n.string("settings.modelState.notInstallable")
        case .termsAcceptanceRequired:
            return L10n.string("settings.modelInstall.termsRequired")
        case .unknownModel:
            return L10n.string("settings.modelInstall.unknownModel")
        case let .transport(message):
            return message
        }
    }
}

enum SpeechModelRemovalError: LocalizedError, Equatable {
    case configured(String)
    case inUse(String)
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case .configured: return L10n.string("settings.modelRemove.configured")
        case .inUse: return L10n.string("settings.modelRemove.inUse")
        case .notInstalled: return L10n.string("settings.modelRemove.notInstalled")
        }
    }
}

enum SpeechModelProductAction: Equatable {
    case install
    case cancelInstall
    case select
    case remove
    case revokeTerms
}

struct SpeechModelProductActions: Equatable {
    let available: [SpeechModelProductAction]
    let removalBlock: SpeechModelRemovalError?
}

struct SpeechModelTermsAcceptanceStore {
    private static let defaultsKey = "speechModelAcceptedTerms.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isAccepted(modelID: String, fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        return acceptedIdentities.contains(identity(modelID: modelID, fingerprint: fingerprint))
    }

    func accept(modelID: String, fingerprint: String) {
        var identities = acceptedIdentities
        identities.insert(identity(modelID: modelID, fingerprint: fingerprint))
        defaults.set(Array(identities).sorted(), forKey: Self.defaultsKey)
    }

    func revoke(modelID: String, fingerprint: String) {
        var identities = acceptedIdentities
        identities.remove(identity(modelID: modelID, fingerprint: fingerprint))
        defaults.set(Array(identities).sorted(), forKey: Self.defaultsKey)
    }

    private var acceptedIdentities: Set<String> {
        Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    private func identity(modelID: String, fingerprint: String) -> String {
        "\(modelID):\(fingerprint)"
    }
}

/// Presentation helpers never participate in persisted model or voice identity.
struct SpeechModelLibraryViewState: Sendable {
    let snapshot: SpeechModelSnapshot?

    static let empty = Self(snapshot: nil)

    var entries: [SpeechModelSnapshot.Entry] { snapshot?.entries ?? [] }

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

    func details(
        for entry: SpeechModelSnapshot.Entry,
        configuredSelections: [TtsSelection] = []
    ) -> String {
        var fields = [status(for: entry)]
        if isConfigured(entry, selections: configuredSelections) {
            fields.append(L10n.string("settings.modelState.configured"))
        }
        if let downloadBytes = entry.distribution.downloadBytes {
            fields.append(L10n.string(
                "settings.modelSize.download",
                ByteCountFormatter.string(fromByteCount: Int64(downloadBytes), countStyle: .file)
            ))
        }
        if let installedBytes = entry.installation.installedBytes ?? entry.distribution.installedBytes {
            fields.append(L10n.string(
                "settings.modelSize.installed",
                ByteCountFormatter.string(fromByteCount: Int64(installedBytes), countStyle: .file)
            ))
        }
        fields.append(L10n.string("settings.modelPerformance.unmeasured"))
        fields.append(languageEvidence(for: entry))
        fields.append(licenceStatus(for: entry))
        fields.append(compatibilityStatus(for: entry))
        return fields.joined(separator: " · ")
    }

    func isConfigured(
        _ entry: SpeechModelSnapshot.Entry,
        selections: [TtsSelection]
    ) -> Bool {
        selections.contains {
            $0.engine == entry.identity.provider && $0.modelID == entry.identity.modelID
        }
    }

    func selection(for entry: SpeechModelSnapshot.Entry) -> TtsSelection? {
        selectableChoices.first { choice in
            choice.selection.engine == entry.identity.provider
                && choice.selection.modelID == entry.identity.modelID
        }?.selection
    }

    func actions(
        for entry: SpeechModelSnapshot.Entry,
        configuredSelections: [TtsSelection],
        installEvent: SpeechModelInstallEvent?,
        termsAccepted: Bool
    ) -> SpeechModelProductActions {
        if installEvent?.isActive == true {
            return SpeechModelProductActions(
                available: [.cancelInstall],
                removalBlock: .inUse(entry.identity.modelID)
            )
        }
        let configured = isConfigured(entry, selections: configuredSelections)
        var available: [SpeechModelProductAction] = []
        if entry.distribution.installable, entry.compatibility.compatible,
           entry.installation.state != .installed {
            available.append(.install)
        }
        if entry.selection.selectable, !configured {
            available.append(.select)
        }
        let removalBlock: SpeechModelRemovalError?
        if entry.installation.state != .installed {
            removalBlock = .notInstalled(entry.identity.modelID)
        } else if configured {
            removalBlock = .configured(entry.identity.modelID)
        } else {
            removalBlock = nil
            available.append(.remove)
        }
        if entry.licence.requiresAcceptance, termsAccepted {
            available.append(.revokeTerms)
        }
        return SpeechModelProductActions(available: available, removalBlock: removalBlock)
    }

    func installTitle(for entry: SpeechModelSnapshot.Entry) -> String {
        let key = entry.installation.state == .installed
            ? "settings.modelInstalled" : "settings.modelInstall"
        return L10n.string(key, displayName(for: entry))
    }

    func installStatus(for event: SpeechModelInstallEvent) -> String {
        if let failure = event.failure {
            switch failure.kind {
            case "insufficient_space":
                guard let required = failure.requiredBytes,
                      let available = failure.availableBytes else {
                    return L10n.string("settings.modelInstall.failed")
                }
                return L10n.string(
                    "settings.modelInstall.insufficientSpace",
                    ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
                )
            case "checksum_mismatch", "verification_failed":
                return L10n.string("settings.modelInstall.verificationFailed")
            case "http_failure", "transport_failed", "transport_start_failed",
                 "transport_write_failed":
                return L10n.string("settings.modelInstall.downloadFailed")
            case "cancelled":
                return L10n.string("settings.modelInstall.cancelled")
            default:
                return L10n.string("settings.modelInstall.failed")
            }
        }
        switch event.stage {
        case .preflight: return L10n.string("settings.modelInstall.preparing")
        case .downloading:
            let fraction = event.bytesTotal == 0 ? 0
                : Double(event.bytesCompleted) / Double(event.bytesTotal)
            return L10n.string("settings.modelInstall.downloading", Int(fraction * 100))
        case .verifying: return L10n.string("settings.modelInstall.verifying")
        case .publishing: return L10n.string("settings.modelInstall.publishing")
        case .completed: return L10n.string("settings.modelInstall.completed")
        case .cancelled: return L10n.string("settings.modelInstall.cancelled")
        case .failed: return L10n.string("settings.modelInstall.failed")
        }
    }

    func installActionTitle(
        for entry: SpeechModelSnapshot.Entry,
        event: SpeechModelInstallEvent?
    ) -> String {
        guard event?.isActive == true else { return installTitle(for: entry) }
        return L10n.string("settings.modelInstall.cancel")
    }

    func actionTitle(for action: SpeechModelProductAction) -> String {
        switch action {
        case .install: return L10n.string("settings.modelAction.install")
        case .cancelInstall: return L10n.string("settings.modelInstall.cancel")
        case .select: return L10n.string("settings.modelAction.select")
        case .remove: return L10n.string("settings.modelAction.remove")
        case .revokeTerms: return L10n.string("settings.modelAction.revokeTerms")
        }
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

    private func languageEvidence(for entry: SpeechModelSnapshot.Entry) -> String {
        guard !entry.languageEvidence.exactTags.isEmpty else {
            return L10n.string("settings.modelLanguage.routingOnly")
        }
        let labels = entry.languageEvidence.exactTags.map { evidence in
            let locale = Locale.current.localizedString(forIdentifier: evidence.tag) ?? evidence.tag
            let validation = evidence.validation == "runtime_validated"
                ? L10n.string("settings.modelLanguage.runtimeValidated")
                : L10n.string("settings.modelLanguage.artifactDeclared")
            return "\(locale) (\(validation))"
        }
        return L10n.string("settings.modelLanguage.exact", labels.joined(separator: ", "))
    }

    private func licenceStatus(for entry: SpeechModelSnapshot.Entry) -> String {
        guard let identifier = entry.licence.id else {
            return L10n.string("settings.modelLicence.unknown")
        }
        guard entry.licence.validation == "partial" else {
            return L10n.string("settings.modelLicence.unknown")
        }
        return L10n.string("settings.modelLicence.partial", identifier)
    }

    private func compatibilityStatus(for entry: SpeechModelSnapshot.Entry) -> String {
        guard !entry.compatibility.compatible else {
            return L10n.string("settings.modelCompatibility.compatible")
        }
        let reasons = entry.compatibility.reasons.map { reason -> String in
            switch reason {
            case "unsupported_language": return L10n.string("settings.modelCompatibility.language")
            case "unsupported_platform": return L10n.string("settings.modelCompatibility.platform")
            case "android_api_too_low": return L10n.string("settings.modelCompatibility.androidAPI")
            case "quality_disabled": return L10n.string("settings.modelCompatibility.quality")
            default: return L10n.string("settings.modelCompatibility.unknown")
            }
        }
        return L10n.string("settings.modelCompatibility.incompatible", reasons.joined(separator: ", "))
    }
}

extension SpeechModelInstallEvent {
    var isActive: Bool {
        switch stage {
        case .preflight, .downloading, .verifying, .publishing: return true
        case .completed, .cancelled, .failed: return false
        }
    }
}
