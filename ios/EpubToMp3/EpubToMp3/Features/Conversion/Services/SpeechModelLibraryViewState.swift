import Foundation

enum SpeechModelInstallationError: LocalizedError, Equatable {
    case duplicate(String)
    case failure(SpeechModelInstallEvent.Failure)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case let .duplicate(modelID):
            return "A model installation is already active for \(modelID)"
        case let .failure(failure):
            return failure.message
        case let .transport(message):
            return message
        }
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

extension SpeechModelInstallEvent {
    var isActive: Bool {
        switch stage {
        case .preflight, .downloading, .verifying, .publishing: return true
        case .completed, .cancelled, .failed: return false
        }
    }
}
