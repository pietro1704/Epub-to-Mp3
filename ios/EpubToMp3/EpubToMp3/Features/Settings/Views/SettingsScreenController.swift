#if os(iOS)
import UIKit

@MainActor
final class SettingsScreenController: UITableViewController {
    private typealias Section = SettingsSection
    private var cellPresentation: SettingsCellPresentation {
        SettingsCellPresentation(tableView: tableView, settings: settings,
                                 storageUsage: storageUsage, diagnosticsSession: diagnosticsSession)
    }
    private lazy var choicePresentation = ReaderPlaybackSettingsChoices(
        controller: self, settings: settings, player: player,
        playbackSection: Section.playback.rawValue, readerSection: Section.reader.rawValue)

    private lazy var storageActions = StorageSettingsActions(
        controller: self, library: library, storageSection: Section.storage.rawValue,
        refreshStorageUsage: { [weak self] in self?.refreshStorageUsage() }
    )

    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock
    private let speechModels: SpeechModelLibraryClient
    private let termsAcceptance: SpeechModelTermsAcceptanceStore
    private var speechModelState: SpeechModelLibraryViewState
    private var speechModelsTask: Task<Void, Never>?
    private var speechModelInstallTasks: [String: Task<Void, Never>] = [:]
    private var speechModelInstallEvents: [String: SpeechModelInstallEvent] = [:]
    private var storageUsage = StorageUsageScanner.current()
    private let diagnosticsSession: StreamingDiagnosticsSession
    private let confirmStreamingDiagnostics: ((String, String, @escaping () -> Void) -> Void)?
    private var diagnosticsExpiryTask: Task<Void, Never>?

    init(settings: AppSettings, library: LibraryStore, player: AudioPlayer, playbackClock: PlaybackClock,
         diagnosticsSession: StreamingDiagnosticsSession? = nil,
         confirmStreamingDiagnostics: ((String, String, @escaping () -> Void) -> Void)? = nil,
         termsAcceptance: SpeechModelTermsAcceptanceStore = .init(),
         speechModels: SpeechModelLibraryClient = .shared) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playbackClock = playbackClock
        self.speechModels = speechModels
        self.termsAcceptance = termsAcceptance
        self.speechModelState = SpeechModelLibraryViewState(snapshot: speechModels.initialSnapshot)
        self.diagnosticsSession = diagnosticsSession ?? .shared
        self.confirmStreamingDiagnostics = confirmStreamingDiagnostics
        super.init(style: .insetGrouped)
        title = L10n.string("settings.title")
        tabBarItem = UITabBarItem(
            title: L10n.string("nav.settings"),
            image: UIImage(systemName: "gearshape"),
            tag: 0
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.accessibilityLabel = L10n.string("settings.title")
        tableView.register(IOSContentCell.self, forCellReuseIdentifier: "Cell")
        tableView.register(IOSInlineTextFieldCell.self, forCellReuseIdentifier: "TextField")
        tableView.register(IOSSwitchCell.self, forCellReuseIdentifier: "Switch")
        reloadSpeechModels()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStorageUsage()
        tableView.reloadData()
        scheduleDiagnosticsExpiryRefresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        diagnosticsExpiryTask?.cancel()
        diagnosticsExpiryTask = nil
    }

    deinit {
        diagnosticsExpiryTask?.cancel()
        speechModelsTask?.cancel()
        speechModelInstallTasks.values.forEach { $0.cancel() }
    }

    func refreshFromStores() {
        guard isViewLoaded else { return }
        refreshStorageUsage()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section)?.rowCount(speechModels: speechModelState) ?? 0
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section)?.footer(settings: settings)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }
        switch section {
        case .runtime:
            return RuntimeSettingsRows.cell(for: indexPath, tableView: tableView, settings: settings,
                                            speechModels: speechModelState,
                                            installEvents: speechModelInstallEvents,
                                            termsAcceptance: termsAcceptance,
                                            controller: self)
        case .backend:
            return RuntimeSettingsRows.backendCell(for: indexPath, tableView: tableView, settings: settings, controller: self)
        case .reader:
            return ReaderSettingsRows(tableView: tableView, settings: settings).cell(for: indexPath)
        case .playback:
            return PlaybackSettingsRows(tableView: tableView, settings: settings).cell(for: indexPath)
        case .storage:
            return cellPresentation.storageCell(for: indexPath)
        case .advanced:
            return cellPresentation.advancedCell(for: indexPath)
        case .about:
            return cellPresentation.aboutCell(for: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .runtime:
            handleRuntimeSelection(row: indexPath.row, source: indexPath)
        case .reader:
            choicePresentation.handleReaderSelection(row: indexPath.row)
        case .playback:
            choicePresentation.handlePlaybackSelection(row: indexPath.row)
        case .storage:
            storageActions.handleSelection(row: indexPath.row)
        case .advanced:
            handleAdvancedSelection(row: indexPath.row)
        case .about:
            RuntimeSettingsRows.handleAboutSelection(row: indexPath.row)
        case .backend:
            break
        }
    }

    private func handleRuntimeSelection(row index: Int, source: IndexPath) {
        guard let row = RuntimeSettingsRows.row(at: index, speechModels: speechModelState) else { return }
        switch row {
        case .primary: presentPrimaryChoices(source: source)
        case .secondary: presentSecondaryChoices(source: source)
        case .studyLanguage:
            SettingsAlertPresentation.studyLanguage(
                state: speechModelState, speechModels: speechModels, on: self,
                tableView: tableView, source: source
            ) { [weak self] snapshot in
                guard let self else { return }
                speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                tableView.reloadData()
            }
        case let .model(entry?): presentModelActions(for: entry, source: source)
        case .cellular, .model(nil), .onlineFallback: break
        }
    }

    private func presentPrimaryChoices(source indexPath: IndexPath) {
        let alert = UIAlertController(
            title: L10n.string("settings.audioEngineChoice"),
            message: L10n.string("settings.audioEngineChoiceDescription"),
            preferredStyle: .actionSheet
        )
        for engine in AudioEnginePreference.supportedPreferences where engine != .piper {
            let selection = TtsSelection.selected(engine)
            alert.addAction(UIAlertAction(
                title: speechModelState.displayName(for: selection), style: .default
            ) { [weak self] _ in
                self?.settings.audioEngine = engine
                self?.tableView.reloadData()
            })
        }
        for choice in speechModelState.selectableChoices {
            alert.addAction(UIAlertAction(title: choice.title, style: .default) { [weak self] _ in
                self?.settings.selectPrimaryNarration(choice.selection)
                self?.tableView.reloadData()
            })
        }
        SettingsAlertPresentation.actionSheet(alert, on: self, tableView: tableView, source: indexPath)
    }

    private func presentSecondaryChoices(source indexPath: IndexPath) {
        let alert = UIAlertController(
            title: L10n.string("settings.secondaryVoice"), message: nil, preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: L10n.string("settings.noSecondary"), style: .default) { [weak self] _ in
            self?.settings.selectSecondaryNarration(nil)
            self?.tableView.reloadData()
        })
        for engine in settings.selectableSecondaryAudioEngines where engine != .piper {
            alert.addAction(UIAlertAction(title: engine.displayName, style: .default) { [weak self] _ in
                guard let self, self.settings.selectableSecondaryAudioEngines.contains(engine) else { return }
                self.settings.secondaryAudioEngine = engine
                self.tableView.reloadData()
            })
        }
        for choice in speechModelState.selectableChoices
            where !choice.selection.representsSameRequest(as: settings.ttsPreferences.primary) {
            alert.addAction(UIAlertAction(title: choice.title, style: .default) { [weak self] _ in
                self?.settings.selectSecondaryNarration(choice.selection)
                self?.tableView.reloadData()
            })
        }
        SettingsAlertPresentation.actionSheet(alert, on: self, tableView: tableView, source: indexPath)
    }

    private func presentModelActions(for entry: SpeechModelSnapshot.Entry, source: IndexPath) {
        let modelID = entry.identity.modelID
        let actions = speechModelState.actions(
            for: entry,
            configuredSelections: settings.configuredNarrationSelections,
            installEvent: speechModelInstallEvents[modelID],
            termsAccepted: termsAcceptance.isAccepted(
                modelID: modelID,
                fingerprint: entry.licence.termsFingerprint
            )
        )
        guard !actions.available.isEmpty else { return }
        let alert = UIAlertController(
            title: speechModelState.displayName(for: entry),
            message: speechModelState.details(
                for: entry,
                configuredSelections: settings.configuredNarrationSelections
            ),
            preferredStyle: .actionSheet
        )
        for action in actions.available {
            alert.addAction(UIAlertAction(
                title: speechModelState.actionTitle(for: action),
                style: action == .remove || action == .cancelInstall || action == .revokeTerms
                    ? .destructive : .default
            ) { [weak self] _ in
                self?.perform(action, for: entry)
            })
        }
        SettingsAlertPresentation.actionSheet(alert, on: self, tableView: tableView, source: source)
    }

    private func perform(_ action: SpeechModelProductAction, for entry: SpeechModelSnapshot.Entry) {
        switch action {
        case .install: confirmInstall(entry)
        case .cancelInstall:
            Task { await speechModels.cancelInstall(modelID: entry.identity.modelID) }
        case .select:
            guard let selection = speechModelState.selection(for: entry) else { return }
            settings.selectPrimaryNarration(selection)
            tableView.reloadData()
        case .remove: confirmRemoval(entry)
        case .revokeTerms:
            guard let fingerprint = entry.licence.termsFingerprint else { return }
            termsAcceptance.revoke(modelID: entry.identity.modelID, fingerprint: fingerprint)
            tableView.reloadData()
        }
    }

    private func confirmInstall(_ entry: SpeechModelSnapshot.Entry) {
        let title = speechModelState.installTitle(for: entry)
        SettingsAlertPresentation.confirmModelInstall(
            entry, state: speechModelState,
            configuredSelections: settings.configuredNarrationSelections,
            termsAcceptance: termsAcceptance, on: self
        ) { [weak self] acceptedTermsFingerprint in
            self?.install(entry, title: title, acceptedTermsFingerprint: acceptedTermsFingerprint)
        }
    }

    private func install(
        _ entry: SpeechModelSnapshot.Entry,
        title: String,
        acceptedTermsFingerprint: String?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await speechModels.install(
                    modelID: entry.identity.modelID,
                    acceptedTermsFingerprint: acceptedTermsFingerprint
                )
                if let snapshot = try? await speechModels.snapshot() {
                    speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                    observeInstalls(in: snapshot.entries)
                }
            } catch is CancellationError {
                // Cancellation is already rendered by the operation event.
            } catch {
                let failure = UIAlertController(title: title,
                    message: AppErrorReporter.message(error, context: #function), preferredStyle: .alert)
                failure.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                present(failure, animated: true)
            }
            tableView.reloadData()
        }
    }

    private func confirmRemoval(_ entry: SpeechModelSnapshot.Entry) {
        SettingsAlertPresentation.confirmModelRemoval(
            entry, state: speechModelState, on: self
        ) { [weak self] in self?.remove(entry) }
    }

    private func remove(_ entry: SpeechModelSnapshot.Entry) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await speechModels.remove(
                    modelID: entry.identity.modelID,
                    configuredSelections: settings.configuredNarrationSelections
                )
                speechModelInstallEvents.removeValue(forKey: entry.identity.modelID)
                speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                tableView.reloadData()
            } catch {
                let alert = UIAlertController(
                    title: L10n.string("settings.modelRemove.failed"),
                    message: AppErrorReporter.message(error, context: #function),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func reloadSpeechModels() {
        speechModelsTask?.cancel()
        speechModelsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await speechModels.snapshot()
                guard !Task.isCancelled else { return }
                speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                observeInstalls(in: snapshot.entries)
                tableView.reloadSections(IndexSet(integer: Section.runtime.rawValue), with: .none)
            } catch {
                // Fail closed: keep existing selections and the last valid presentation.
            }
        }
    }

    private func observeInstalls(in entries: [SpeechModelSnapshot.Entry]) {
        speechModelInstallTasks.values.forEach { $0.cancel() }
        speechModelInstallTasks.removeAll()
        for entry in entries where entry.distribution.installable {
            let modelID = entry.identity.modelID
            speechModelInstallTasks[modelID] = Task { [weak self] in
                guard let self else { return }
                let events = await speechModels.watchInstall(modelID: modelID)
                for await event in events {
                    guard !Task.isCancelled else { return }
                    speechModelInstallEvents[modelID] = event
                    if event.stage == .completed,
                       let snapshot = try? await speechModels.snapshot() {
                        speechModelInstallEvents.removeValue(forKey: modelID)
                        speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                    }
                    tableView.reloadSections(IndexSet(integer: Section.runtime.rawValue), with: .none)
                }
            }
        }
    }

    private func handleAdvancedSelection(row: Int) {
        if row == 0 {
            navigationController?.pushViewController(
                JobsListScreenController(
                    settings: settings,
                    library: library,
                    player: player,
                    playbackClock: playbackClock
                ),
                animated: true
            )
        } else if row == 1 {
            navigationController?.pushViewController(
                TelemetryScreenController(settings: settings),
                animated: true
            )
        } else if row == 2 {
            exportPerformanceDiagnostics()
        } else if row == 3 {
            toggleStreamingDiagnostics()
        } else {
            SettingsAlertPresentation.destructive(on: self,
                title: L10n.string("settings.clearCacheConfirmTitle"),
                message: L10n.string("settings.clearCacheConfirmMessage"),
                buttonTitle: L10n.string("settings.clearCacheConfirmButton")
            ) { [weak self] in
                guard let self else { return }
                self.storageActions.clearAllDownloads()
                SettingsAlertPresentation.info(on: self, title: L10n.string("settings.clearCacheDone"))
            }
        }
    }

    private func exportPerformanceDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await LatencyObservationStore.shared.writeDiagnosticExport()
                let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = view
                    popover.sourceRect = view.bounds
                }
                present(controller, animated: true)
            } catch {
                SettingsAlertPresentation.info(on: self,
                    title: L10n.string("settings.exportPerformanceDiagnostics"),
                    message: AppErrorReporter.message(L10n.string("settings.exportPerformanceDiagnosticsError"), context: "Diagnostics export: \(error.localizedDescription)")
                )
            }
        }
    }

    private func toggleStreamingDiagnostics() {
        if diagnosticsSession.isActive {
            diagnosticsSession.deactivate()
            refreshStreamingDiagnostics()
            return
        }
        let title = L10n.string("settings.streamingDiagnosticsConfirmTitle")
        let message = L10n.string("settings.streamingDiagnosticsConfirmMessage")
        let enable: () -> Void = { [weak self] in
            guard let self else { return }
            _ = self.diagnosticsSession.activate()
            self.refreshStreamingDiagnostics()
        }
        if let confirmStreamingDiagnostics {
            confirmStreamingDiagnostics(title, message, enable)
        } else {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.string("settings.enableStreamingDiagnostics"), style: .default) { _ in enable() })
            present(alert, animated: true)
        }
    }

    private func refreshStreamingDiagnostics() {
        tableView.reloadRows(at: [IndexPath(row: 3, section: Section.advanced.rawValue)], with: .none)
        scheduleDiagnosticsExpiryRefresh()
    }

    private func scheduleDiagnosticsExpiryRefresh() {
        diagnosticsExpiryTask?.cancel()
        diagnosticsExpiryTask = nil
        let remaining = diagnosticsSession.remainingTime
        guard remaining > 0 else { return }
        diagnosticsExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64((remaining + 0.05) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.refreshStreamingDiagnostics()
        }
    }

    private func refreshStorageUsage() {
        storageUsage = StorageUsageScanner.current(budgetBytes: settings.offlineCacheBudgetBytes)
    }


}
#endif
