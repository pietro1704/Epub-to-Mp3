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

    let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock
    let speechModels: SpeechModelLibraryClient
    let termsAcceptance: SpeechModelTermsAcceptanceStore
    /// Catalogue and install events behind the Models row summary.
    let modelLibrary: SpeechModelLibrarySession
    var speechModelState: SpeechModelLibraryViewState { modelLibrary.state }
    var speechModelInstallEvents: [String: SpeechModelInstallEvent] { modelLibrary.installEvents }
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
        self.modelLibrary = SpeechModelLibrarySession(client: speechModels)
        self.diagnosticsSession = diagnosticsSession ?? .shared
        self.confirmStreamingDiagnostics = confirmStreamingDiagnostics
        super.init(style: .insetGrouped)
        bindModelLibrary()
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
    }

    func refreshFromStores() {
        guard isViewLoaded else { return }
        refreshStorageUsage()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section)?.rowCount ?? 0
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
            return modelsCell(at: indexPath)
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
            navigationController?.pushViewController(makeModelsScreen(), animated: true)
        case .reader:
            choicePresentation.handleReaderSelection(row: indexPath.row)
        case .playback:
            choicePresentation.handlePlaybackSelection(row: indexPath.row)
        case .storage:
            storageActions.handleSelection(row: indexPath.row)
        case .advanced:
            handleAdvancedSelection(row: indexPath.row)
        case .about:
            openProjectPage(row: indexPath.row)
        }
    }

    /// The single Models entry of Settings: models by language, one choice per
    /// language, with install, remove, preview and licence actions in the screen.
    func makeModelsScreen(focusLanguage: String? = nil) -> ModelsScreenController {
        ModelsScreenController(settings: settings, source: SpeechModelsSource(client: speechModels),
                               termsAcceptance: termsAcceptance, focusLanguage: focusLanguage)
    }

    private func openProjectPage(row: Int) {
        guard row == 2, let url = URL(string: "https://github.com/pietro1704/Epub-to-Mp3") else { return }
        UIApplication.shared.open(url)
    }

    private func bindModelLibrary() {
        modelLibrary.onChange = { [weak self] change in
            switch change {
            case .installProgress: self?.refreshInstallProgress()
            case .catalog: self?.tableView.reloadData()
            }
        }
        modelLibrary.onFailure = { [weak self] title, error, operation in
            guard let self else { return }
            let alert = UIAlertController(title: title,
                message: AppErrorReporter.message(error, context: operation), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private func handleAdvancedSelection(row: Int) {
        switch row {
        case SettingsCellPresentation.AdvancedRow.exportPerformanceDiagnostics.rawValue:
            exportPerformanceDiagnostics()
        case SettingsCellPresentation.AdvancedRow.streamingDiagnostics.rawValue:
            toggleStreamingDiagnostics()
        default:
            break
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
        tableView.reloadRows(at: [IndexPath(row: SettingsCellPresentation.AdvancedRow.streamingDiagnostics.rawValue,
                                            section: Section.advanced.rawValue)], with: .none)
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
        storageUsage = StorageUsageScanner.current()
    }


}
#endif
