import AVFoundation
import Foundation
import Combine

/// What the Models screen needs from the speech model library; the real source
/// wraps `SpeechModelLibraryClient`, tests use a fake.
protocol ModelsByLanguageSource: Sendable {
    func catalogLanguages() async throws -> [CatalogLanguage]
    func snapshot(language: String) async throws -> SpeechModelSnapshot
    func install(modelID: String, acceptedTermsFingerprint: String?, language: String) async throws
    func watchInstall(modelID: String) async -> AsyncStream<SpeechModelInstallEvent>
    func cancelInstall(modelID: String) async
}

struct SpeechModelsSource: ModelsByLanguageSource {
    let client: SpeechModelLibraryClient

    init(client: SpeechModelLibraryClient = .shared) { self.client = client }

    func catalogLanguages() async throws -> [CatalogLanguage] { try await client.catalogLanguages() }
    func snapshot(language: String) async throws -> SpeechModelSnapshot { try await client.languageSnapshot(language) }
    func install(modelID: String, acceptedTermsFingerprint: String?, language: String) async throws {
        _ = try await client.install(modelID: modelID, acceptedTermsFingerprint: acceptedTermsFingerprint, language: language)
    }
    func watchInstall(modelID: String) async -> AsyncStream<SpeechModelInstallEvent> {
        await client.watchInstall(modelID: modelID)
    }
    func cancelInstall(modelID: String) async { await client.cancelInstall(modelID: modelID) }
}

/// Drives the Models screen: loads the catalog by language, applies the user's
/// per-language choice, and starts downloads only on an explicit tap.
@MainActor
final class ModelsByLanguageModel: ObservableObject {
    @Published private(set) var state = ModelsByLanguageViewState(sections: [])
    /// Download progress 0...1 per row id while a download is active.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailure: String?
    /// A licence the user must accept before the model can download.
    @Published private(set) var pendingTerms: PendingTerms?

    struct PendingTerms: Equatable {
        let row: ModelsByLanguageViewState.Row
        let language: String
        let fingerprint: String
    }

    private let source: ModelsByLanguageSource
    private let settings: AppSettings
    private let systemVoiceLanguages: @Sendable () -> Set<String>
    private let terms: SpeechModelTermsAcceptanceStore
    private var snapshots: [(tag: String, snapshot: SpeechModelSnapshot)] = []
    private var watchers: [String: Task<Void, Never>] = [:]
    private var settingsObservation: AnyCancellable?

    init(source: ModelsByLanguageSource = SpeechModelsSource(),
         settings: AppSettings,
         terms: SpeechModelTermsAcceptanceStore = SpeechModelTermsAcceptanceStore(),
         systemVoiceLanguages: (@Sendable () -> Set<String>)? = nil) {
        self.source = source
        self.settings = settings
        self.terms = terms
        self.systemVoiceLanguages = systemVoiceLanguages ?? Self.installedSystemVoiceLanguages
        settingsObservation = settings.objectWillChange.sink { [weak self] _ in
            // Settings publish before the value moves; recompute after it did.
            Task { @MainActor in self?.rebuild() }
        }
    }

    /// Languages (base tags) that have an installed system voice.
    nonisolated static let installedSystemVoiceLanguages: @Sendable () -> Set<String> = {
        #if canImport(AVFoundation)
        return Set(AVSpeechSynthesisVoice.speechVoices().map { SpeechPreferences.languageKey($0.language) })
        #else
        return []
        #endif
    }

    func load() async {
        isLoading = true
        loadFailure = nil
        defer { isLoading = false }
        do {
            let languages = try await source.catalogLanguages()
            var loaded: [(tag: String, snapshot: SpeechModelSnapshot)] = []
            for language in languages {
                loaded.append((language.tag, try await source.snapshot(language: language.tag)))
            }
            snapshots = loaded
            rebuild()
        } catch {
            loadFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Picks `row` for its language. Only a ready row can be chosen: a dimmed row
    /// is downloaded first (explicit) and never selected silently.
    @discardableResult
    func choose(_ row: ModelsByLanguageViewState.Row, in language: String) -> Bool {
        guard row.availability == .ready else { return false }
        settings.selectLanguageModel(row.selection, for: language)
        return true
    }

    func clearChoice(in language: String) { settings.clearLanguageModel(for: language) }

    /// Tapping a dimmed, downloadable row starts its download at once.
    func download(_ row: ModelsByLanguageViewState.Row, in language: String) async {
        guard case .downloadable = row.availability, let modelID = row.selection.modelID,
              watchers[row.id] == nil else { return }
        if let entry = entry(for: row, in: language), entry.licence.requiresAcceptance,
           let fingerprint = entry.licence.termsFingerprint,
           !terms.isAccepted(modelID: modelID, fingerprint: fingerprint) {
            pendingTerms = PendingTerms(row: row, language: language, fingerprint: fingerprint)
            return
        }
        await startDownload(row, language: language, fingerprint: nil)
    }

    func acceptPendingTerms() async {
        guard let pending = pendingTerms, let modelID = pending.row.selection.modelID else { return }
        pendingTerms = nil
        terms.accept(modelID: modelID, fingerprint: pending.fingerprint)
        await startDownload(pending.row, language: pending.language, fingerprint: pending.fingerprint)
    }

    func declinePendingTerms() { pendingTerms = nil }

    func cancelDownload(_ row: ModelsByLanguageViewState.Row) async {
        guard let modelID = row.selection.modelID else { return }
        await source.cancelInstall(modelID: modelID)
    }

    private func startDownload(_ row: ModelsByLanguageViewState.Row, language: String, fingerprint: String?) async {
        guard let modelID = row.selection.modelID else { return }
        failures[row.id] = nil
        progress[row.id] = 0
        let stream = await source.watchInstall(modelID: modelID)
        watchers[row.id] = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.apply(event, row: row, language: language)
                if [.completed, .cancelled, .failed].contains(event.stage) { return }
            }
        }
        do {
            try await source.install(modelID: modelID, acceptedTermsFingerprint: fingerprint, language: language)
        } catch {
            failures[row.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            progress[row.id] = nil
            watchers.removeValue(forKey: row.id)?.cancel()
        }
    }

    private func apply(_ event: SpeechModelInstallEvent, row: ModelsByLanguageViewState.Row, language: String) async {
        switch event.stage {
        case .completed:
            progress[row.id] = nil
            watchers[row.id] = nil
            // The installed model becomes selectable: refresh its language only.
            if let fresh = try? await source.snapshot(language: language),
               let index = snapshots.firstIndex(where: { $0.tag == language }) {
                snapshots[index] = (language, fresh)
                rebuild()
            }
        case .cancelled:
            progress[row.id] = nil
            watchers[row.id] = nil
        case .failed:
            progress[row.id] = nil
            watchers[row.id] = nil
            failures[row.id] = event.failure.map(SpeechModelLibraryViewState.installFailureMessage)
                ?? L10n.string("settings.modelInstall.downloadFailed")
        case .preflight, .downloading, .verifying, .publishing:
            progress[row.id] = event.bytesTotal > 0 ? min(1, Double(event.bytesCompleted) / Double(event.bytesTotal)) : 0
        }
    }

    private func entry(for row: ModelsByLanguageViewState.Row, in language: String) -> SpeechModelSnapshot.Entry? {
        snapshots.first { $0.tag == language }?.snapshot.entries.first {
            $0.identity.modelID == row.selection.modelID && $0.identity.provider == row.selection.engine
        }
    }

    private func rebuild() {
        state = .make(
            languages: snapshots.map { .init(tag: $0.tag, snapshot: $0.snapshot) },
            choices: settings.languageModelChoices,
            allowOnlineFallback: settings.allowOnlineAudioFallback,
            systemVoiceLanguages: systemVoiceLanguages())
    }
}
