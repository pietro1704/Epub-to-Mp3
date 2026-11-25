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
    func remove(modelID: String, configuredSelections: [TtsSelection]) async throws
    func auditionChoice(for entry: SpeechModelSnapshot.Entry) async throws -> (selection: TtsSelection, language: String)
    /// The install browser: the language's models plus the explicit-only Piper Low voices.
    func snapshot(language: String, includeLow: Bool) async throws -> SpeechModelSnapshot
    func install(modelID: String, acceptedTermsFingerprint: String?, language: String, explicitLow: Bool) async throws
    func remove(modelID: String, configuredSelections: [TtsSelection], explicitLowLanguage: String?) async throws
    /// The selection that names an installed Low voice with its catalogue revision.
    func explicitSelection(for entry: SpeechModelSnapshot.Entry, language: String) async throws -> TtsSelection
}

extension ModelsByLanguageSource {
    func snapshot(language: String, includeLow: Bool) async throws -> SpeechModelSnapshot {
        try await snapshot(language: language)
    }
    func install(modelID: String, acceptedTermsFingerprint: String?, language: String, explicitLow: Bool) async throws {
        try await install(modelID: modelID, acceptedTermsFingerprint: acceptedTermsFingerprint, language: language)
    }
    func remove(modelID: String, configuredSelections: [TtsSelection], explicitLowLanguage: String?) async throws {
        try await remove(modelID: modelID, configuredSelections: configuredSelections)
    }
    func explicitSelection(for entry: SpeechModelSnapshot.Entry, language: String) async throws -> TtsSelection {
        throw SpeechModelInstallationError.incompatible(entry.identity.modelID)
    }
}

struct SpeechModelsSource: ModelsByLanguageSource {
    let client: SpeechModelLibraryClient

    init(client: SpeechModelLibraryClient = .shared) { self.client = client }

    func catalogLanguages() async throws -> [CatalogLanguage] { try await client.catalogLanguages() }
    /// The listing only inspects installed files; loading every model's runtime for
    /// every language would take many seconds. A model is chosen on that evidence
    /// (the same the Rust resolver uses) and a runtime failure surfaces on use.
    func snapshot(language: String) async throws -> SpeechModelSnapshot {
        try await client.languageSnapshot(language, probeRuntime: false)
    }
    func install(modelID: String, acceptedTermsFingerprint: String?, language: String) async throws {
        _ = try await client.install(modelID: modelID, acceptedTermsFingerprint: acceptedTermsFingerprint, language: language)
    }
    func watchInstall(modelID: String) async -> AsyncStream<SpeechModelInstallEvent> {
        await client.watchInstall(modelID: modelID)
    }
    func cancelInstall(modelID: String) async { await client.cancelInstall(modelID: modelID) }
    func remove(modelID: String, configuredSelections: [TtsSelection]) async throws {
        _ = try await client.remove(modelID: modelID, configuredSelections: configuredSelections)
    }
    func auditionChoice(for entry: SpeechModelSnapshot.Entry) async throws -> (selection: TtsSelection, language: String) {
        try await client.auditionChoice(for: entry)
    }
    func snapshot(language: String, includeLow: Bool) async throws -> SpeechModelSnapshot {
        includeLow ? try await client.manualLanguageSnapshot(language) : try await snapshot(language: language)
    }
    func install(modelID: String, acceptedTermsFingerprint: String?, language: String, explicitLow: Bool) async throws {
        _ = try await client.install(modelID: modelID, acceptedTermsFingerprint: acceptedTermsFingerprint,
                                     language: language, explicitLow: explicitLow)
    }
    func remove(modelID: String, configuredSelections: [TtsSelection], explicitLowLanguage: String?) async throws {
        _ = try await client.remove(modelID: modelID, configuredSelections: configuredSelections,
                                    explicitLowLanguage: explicitLowLanguage)
    }
    func explicitSelection(for entry: SpeechModelSnapshot.Entry, language: String) async throws -> TtsSelection {
        try await client.explicitSelection(for: entry, language: language)
    }
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
    /// Piper Low voices are explicit-only: hidden until the listener asks to see them. Revealing a voice,
    /// installing it and choosing it are three separate actions; hiding keeps an active explicit choice.
    @Published private(set) var showLowQuality = false
    @Published private(set) var loadFailure: String?
    /// The catalog's languages with their shared popularity rank, as the language screen needs them.
    @Published private(set) var catalogLanguages: [CatalogLanguage] = []
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
    /// Languages whose snapshot is the install browser (it lists Low voices).
    private var lowLanguages: Set<String> = []
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
            catalogLanguages = languages
            snapshots = []
            lowLanguages = []
            for language in languages {
                let includeLow = showLowQuality || hasExplicitLowChoice(in: language.tag)
                snapshots.append((language.tag, try await fetch(language.tag, includeLow: includeLow)))
                // Show languages as they arrive instead of waiting for the whole catalog.
                rebuild()
            }
        } catch {
            loadFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Picks `row` for its language. Only a ready row can be chosen: a dimmed row
    /// is downloaded first (explicit) and never selected silently. A Low voice is never saved bare:
    /// it goes through `chooseExplicit`, which pins its catalogue revision.
    @discardableResult
    func choose(_ row: ModelsByLanguageViewState.Row, in language: String) -> Bool {
        guard row.availability == .ready, !row.isExplicitOnly else { return false }
        settings.selectLanguageModel(row.selection, for: language)
        return true
    }

    /// Chooses an installed Piper Low voice for its language with the revision-pinned selection the core requires.
    @discardableResult
    func chooseExplicit(_ row: ModelsByLanguageViewState.Row, in language: String) async -> Bool {
        guard row.availability == .ready, row.isExplicitOnly, let entry = entry(for: row, in: language) else { return false }
        do {
            let selection = try await source.explicitSelection(for: entry, language: language)
            settings.selectLanguageModel(selection, for: language)
            failures[row.id] = nil
            return true
        } catch {
            failures[row.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Shows or hides the Low voices. Showing loads the install browser for every language; hiding only filters
    /// (an explicit choice that is a Low voice stays visible and chosen).
    func setShowLowQuality(_ value: Bool) async {
        guard showLowQuality != value else { return }
        showLowQuality = value
        guard value else { rebuild(); return }
        for index in snapshots.indices where !lowLanguages.contains(snapshots[index].tag) {
            let tag = snapshots[index].tag
            if let fresh = try? await fetch(tag, includeLow: true),
               let current = snapshots.firstIndex(where: { $0.tag == tag }) {
                snapshots[current] = (tag, fresh)
            }
        }
        rebuild()
    }

    private func fetch(_ language: String, includeLow: Bool) async throws -> SpeechModelSnapshot {
        if includeLow { lowLanguages.insert(language) } else { lowLanguages.remove(language) }
        return includeLow ? try await source.snapshot(language: language, includeLow: true)
                          : try await source.snapshot(language: language)
    }

    /// The language's saved choice is a revision-pinned Piper Low voice, so its row must stay listed.
    private func hasExplicitLowChoice(in language: String) -> Bool {
        settings.languageModelChoices[SpeechPreferences.languageKey(language)].map(Self.isExplicitLow) ?? false
    }

    static func isExplicitLow(_ selection: TtsSelection) -> Bool {
        guard selection.engine == TtsSelection.piperEngine, let id = selection.modelID?.lowercased() else { return false }
        return id.hasSuffix("-low") || id.hasSuffix("_low")
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

    struct NarrationChoice: Equatable, Identifiable {
        let selection: TtsSelection
        let title: String
        var id: String { "\(selection.engine):\(selection.modelID ?? ""):\(selection.voice ?? "")" }
    }

    /// Voices the user may make the default primary or reserve: every ready local
    /// model of any language, the installed system voice, online Edge, and any
    /// configured selection that is not in the catalog (kept so it stays visible).
    var narrationChoices: [NarrationChoice] {
        var choices: [NarrationChoice] = []
        func add(_ selection: TtsSelection, _ title: String) {
            if !choices.contains(where: { $0.selection.representsSameRequest(as: selection) }) {
                choices.append(NarrationChoice(selection: selection, title: title))
            }
        }
        for section in state.sections {
            // Piper Low voices are never offered as the default or reserve voice, only per language.
            for row in section.rows where row.kind == .local && row.selection.engine == TtsSelection.piperEngine
                && row.availability == .ready && !row.isExplicitOnly {
                add(row.selection, row.title)
            }
        }
        add(.systemDefault, L10n.string("settings.systemTts"))
        add(.edgeDefault, TtsSelection.displayName(forEngine: TtsSelection.edgeEngine) ?? "Edge")
        for selection in settings.configuredNarrationSelections { add(selection, title(for: selection)) }
        return choices
    }

    // MARK: engine-first narration menu

    /// The two-level narration choice: the engine first (System, Piper, Edge), then, inside an engine that has
    /// several, its voice or model. Built from the same ready models as `narrationChoices`.
    struct NarrationMenu: Equatable {
        struct Voice: Equatable, Identifiable {
            let title: String
            let selection: TtsSelection
            let isSelected: Bool
            var id: String { "\(selection.engine):\(selection.modelID ?? ""):\(selection.voice ?? "")" }
        }
        struct Engine: Equatable, Identifiable {
            let engine: String
            let title: String
            let isSelected: Bool
            let isEnabled: Bool
            /// Engines without a voice list (System, Edge) select directly.
            let direct: TtsSelection?
            /// Piper: the downloaded models. Empty when none can be chosen.
            let voices: [Voice]
            /// Why a disabled engine is disabled (Edge without the online permission).
            let hint: String?
            var id: String { engine }
            var hasVoiceList: Bool { engine == TtsSelection.piperEngine }
        }
        /// Secondary only: "None" is the first entry and selected when no reserve voice is set.
        let showsNone: Bool
        let noneIsSelected: Bool
        let engines: [Engine]
    }

    func narrationMenu(secondary: Bool) -> NarrationMenu {
        let current = secondary ? secondarySelection : primarySelection
        let primary = primarySelection
        let consent = allowOnlineFallback
        func allowed(_ selection: TtsSelection) -> Bool {
            secondary ? selection.canBeSecondary(to: primary, allowOnlineFallback: consent)
                      : (!selection.isEdge || consent)
        }
        func isSelected(_ selection: TtsSelection) -> Bool { current?.representsSameRequest(as: selection) == true }
        let choices = narrationChoices
        var engines: [NarrationMenu.Engine] = []

        let systemSelection = choices.first { $0.selection.isSystem }?.selection ?? .systemDefault
        engines.append(.init(engine: TtsSelection.systemEngine, title: L10n.string("models.engine.system"),
                             isSelected: current?.isSystem == true, isEnabled: allowed(systemSelection),
                             direct: systemSelection, voices: [], hint: nil))

        let voices = choices.filter { $0.selection.isPiper && allowed($0.selection) }
            .map { NarrationMenu.Voice(title: $0.title, selection: $0.selection, isSelected: isSelected($0.selection)) }
        engines.append(.init(engine: TtsSelection.piperEngine, title: "Piper", isSelected: current?.isPiper == true,
                             isEnabled: !voices.isEmpty, direct: nil, voices: voices,
                             hint: voices.isEmpty ? L10n.string("models.engine.noPiperVoice") : nil))

        let edgeSelection = choices.first { $0.selection.isEdge }?.selection ?? .edgeDefault
        let edgeAllowed = allowed(edgeSelection)
        engines.append(.init(engine: TtsSelection.edgeEngine, title: "Edge", isSelected: current?.isEdge == true,
                             isEnabled: edgeAllowed, direct: edgeSelection, voices: [],
                             hint: consent ? nil : L10n.string("models.needsConsent")))
        return NarrationMenu(showsNone: secondary, noneIsSelected: secondary && current == nil, engines: engines)
    }

    /// The cell's headline: the engine of the current choice ("None" for an empty reserve).
    func engineTitle(for selection: TtsSelection?) -> String {
        guard let selection else { return L10n.string("settings.noSecondary") }
        switch selection.engine {
        case TtsSelection.systemEngine: return L10n.string("models.engine.system")
        default: return TtsSelection.displayName(forEngine: selection.engine) ?? selection.engine
        }
    }

    /// The cell's detail: the voice or model inside the engine.
    func voiceTitle(for selection: TtsSelection?) -> String? {
        guard let selection else { return nil }
        switch selection.engine {
        case TtsSelection.piperEngine: return title(for: selection)
        case TtsSelection.systemEngine: return L10n.string("models.engine.systemDetail")
        default: return nil
        }
    }

    func title(for selection: TtsSelection) -> String {
        if selection.engine == TtsSelection.piperEngine, let id = selection.modelID {
            for section in state.sections {
                if let row = section.rows.first(where: { $0.selection.modelID == id }) { return row.title }
            }
            return id
        }
        return TtsSelection.displayName(forEngine: selection.engine) ?? selection.engine
    }

    /// Choices valid as a reserve for the current primary and consent.
    var secondaryChoices: [NarrationChoice] {
        narrationChoices.filter {
            $0.selection.canBeSecondary(to: settings.primaryTtsSelection, allowOnlineFallback: settings.allowOnlineAudioFallback)
        }
    }

    func selectPrimary(_ selection: TtsSelection) { settings.selectPrimaryNarration(selection) }
    func selectSecondary(_ selection: TtsSelection?) { settings.selectSecondaryNarration(selection) }
    var primarySelection: TtsSelection { settings.primaryTtsSelection }
    var secondarySelection: TtsSelection? { settings.secondaryTtsSelection }
    var allowAutomaticSystemVoiceFallback: Bool {
        get { settings.allowAutomaticSystemVoiceFallback }
        set { settings.allowAutomaticSystemVoiceFallback = newValue }
    }
    var allowOnlineFallback: Bool {
        get { settings.allowOnlineAudioFallback }
        set { settings.allowOnlineAudioFallback = newValue }
    }

    /// The library helpers (names, details, actions) for one language's snapshot.
    func libraryState(for language: String) -> SpeechModelLibraryViewState {
        SpeechModelLibraryViewState(snapshot: snapshots.first { $0.tag == language }?.snapshot)
    }

    /// The Rust entry behind a row, for details, preview and removal.
    func entry(forRow row: ModelsByLanguageViewState.Row, in language: String) -> SpeechModelSnapshot.Entry? {
        entry(for: row, in: language)
    }

    func isTermsAccepted(for entry: SpeechModelSnapshot.Entry) -> Bool {
        terms.isAccepted(modelID: entry.identity.modelID, fingerprint: entry.licence.termsFingerprint)
    }

    func revokeTerms(for entry: SpeechModelSnapshot.Entry) {
        guard let fingerprint = entry.licence.termsFingerprint else { return }
        terms.revoke(modelID: entry.identity.modelID, fingerprint: fingerprint)
        objectWillChange.send()
    }

    /// Every selection that must keep its model: primary, secondary and each language's choice.
    var protectedSelections: [TtsSelection] {
        settings.configuredNarrationSelections + Array(settings.languageModelChoices.values)
    }

    /// Removes an installed model the client allows (not configured, chosen or in use) and refreshes its language.
    func remove(_ row: ModelsByLanguageViewState.Row, in language: String) async throws {
        guard let modelID = row.selection.modelID else { return }
        if row.isExplicitOnly {
            try await source.remove(modelID: modelID, configuredSelections: protectedSelections, explicitLowLanguage: language)
        } else {
            try await source.remove(modelID: modelID, configuredSelections: protectedSelections)
        }
        progress[row.id] = nil
        await refresh(language)
    }

    func auditionChoice(for row: ModelsByLanguageViewState.Row, in language: String) async throws
        -> (selection: TtsSelection, language: String) {
        guard let entry = entry(for: row, in: language) else { throw SpeechModelInstallationError.unknownModel(row.id) }
        return try await source.auditionChoice(for: entry)
    }

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
            if row.isExplicitOnly {
                try await source.install(modelID: modelID, acceptedTermsFingerprint: fingerprint, language: language, explicitLow: true)
            } else {
                try await source.install(modelID: modelID, acceptedTermsFingerprint: fingerprint, language: language)
            }
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
            await refresh(language)
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

    /// Reloads one language's snapshot, keeping the Low voices listed when that language already shows them.
    private func refresh(_ language: String) async {
        let includeLow = lowLanguages.contains(language)
        guard let fresh = try? await fetch(language, includeLow: includeLow),
              let index = snapshots.firstIndex(where: { $0.tag == language }) else { return }
        snapshots[index] = (language, fresh)
        rebuild()
    }

    private func entry(for row: ModelsByLanguageViewState.Row, in language: String) -> SpeechModelSnapshot.Entry? {
        snapshots.first { $0.tag == language }?.snapshot.entries.first {
            $0.identity.modelID == row.selection.modelID && $0.identity.provider == row.selection.engine
        }
    }

    /// The book's language: its groups come first so the screen opens on it.
    var priorityLanguage: String? {
        didSet { if oldValue != priorityLanguage { rebuild() } }
    }

    private func rebuild() {
        let made = ModelsByLanguageViewState.make(
            languages: snapshots.map { .init(tag: $0.tag, snapshot: $0.snapshot) },
            choices: settings.languageModelChoices,
            allowOnlineFallback: settings.allowOnlineAudioFallback,
            systemVoiceLanguages: systemVoiceLanguages(),
            showLowQuality: showLowQuality)
        guard let focus = priorityLanguage.map(SpeechPreferences.languageKey),
              let index = made.sections.firstIndex(where: { $0.language == focus }), index > 0 else {
            state = made
            return
        }
        var sections = made.sections
        sections.insert(sections.remove(at: index), at: 0)
        state = ModelsByLanguageViewState(sections: sections)
    }
}

// MARK: A2 - the language-first root of Models

extension ModelsByLanguageModel {
    /// The rows of the root ("the voice for each language"): which languages appear and what each resolves to now.
    /// Rust resolves; this only gathers its inputs (the language's choice, the saved default, what is installed,
    /// the system voices, the consent and the system-voice setting). `resolve` is a seam for tests.
    func rootRows(
        systemLanguages: [String] = Locale.preferredLanguages, bookLanguages: [String] = [],
        resolve: ((LanguageModelResolutionRequest) -> LanguageModelResolution?)? = nil
    ) -> [ModelsRootRows.Row] {
        // What is installed, from the loaded catalog: the ready local voices and the languages they belong to.
        var installedIDs: [String] = []
        var installedLanguages: [String] = []
        for section in state.sections {
            let ready = section.local.filter { $0.availability == .ready && $0.selection.engine == TtsSelection.piperEngine }
            guard !ready.isEmpty else { continue }
            installedLanguages.append(section.language)
            installedIDs.append(contentsOf: ready.compactMap(\.selection.modelID))
        }
        let systemVoices = Array(systemVoiceLanguages()).sorted()
        let resolver = resolve ?? { try? ConverterFFIAdapter().resolveLanguageModel($0) }
        var input = ModelsRootRows.Input()
        input.systemLanguages = systemLanguages
        input.bookLanguages = bookLanguages
        input.choices = settings.languageModelChoices
        input.installedLanguages = installedLanguages
        input.resolution = { [settings] language in
            var request = LanguageModelResolutionRequest(bookLanguage: language, platform: LanguageModelResolutionRequest.currentPlatform)
            request.perLanguageChoices = settings.languageModelChoices
            request.primary = settings.primaryTtsSelection
            request.allowOnlineFallback = settings.allowOnlineAudioFallback
            request.allowAutomaticSystemVoiceFallback = settings.allowAutomaticSystemVoiceFallback
            request.installedModelIDs = installedIDs
            request.systemVoices = systemVoices
            return resolver(request)
        }
        return ModelsRootRows.rows(input)
    }

    /// A root row as the screens draw it.
    struct RootItem: Equatable, Identifiable {
        let language: String
        let title: String
        /// The voice that reads the language now, or why none does.
        let detail: String
        let needsVoice: Bool
        var id: String { language }
    }

    /// The root rows ready to draw; the language the screen was opened for comes first.
    func rootItems(
        systemLanguages: [String] = Locale.preferredLanguages, bookLanguages: [String],
        priority: String? = nil, uiLocale: Locale = .current,
        resolve: ((LanguageModelResolutionRequest) -> LanguageModelResolution?)? = nil
    ) -> [RootItem] {
        var items = rootRows(systemLanguages: systemLanguages, bookLanguages: bookLanguages, resolve: resolve).map { row in
            let name = ModelLanguageOrder.displayName(row.language, in: uiLocale)
            return RootItem(language: row.language, title: name.prefix(1).uppercased() + name.dropFirst(),
                            detail: rootDetail(row), needsVoice: row.needsVoice)
        }
        if let focus = priority.map(SpeechPreferences.languageKey),
           let index = items.firstIndex(where: { $0.language == focus }) {
            items.insert(items.remove(at: index), at: 0)
        }
        return items
    }

    private func rootDetail(_ row: ModelsRootRows.Row) -> String {
        guard let resolution = row.resolution else { return "" }
        switch resolution.status {
        case .missingModel: return L10n.string("models.root.noVoice")
        case .systemFallback: return L10n.string("models.engine.system")
        case .selected: return resolution.selection.map(title(for:)) ?? ""
        }
    }
}
