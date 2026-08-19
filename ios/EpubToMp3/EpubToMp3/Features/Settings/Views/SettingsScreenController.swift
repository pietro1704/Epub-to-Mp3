#if os(iOS)
import UIKit

@MainActor
final class SettingsScreenController: UITableViewController {
    private static var platformMinimumLabel: String {
        let info = Bundle.main.infoDictionary
        if let version = info?["MinimumOSVersion"] as? String, !version.isEmpty {
            return "iOS \(version)+"
        }
        return "iOS 15.0+"
    }
    private enum Section: Int, CaseIterable {
        case runtime
        case backend
        case playback
        case reader
        case storage
        case advanced
        case about
    }

    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock
    private var storageUsage = StorageUsageScanner.current()

    init(settings: AppSettings, library: LibraryStore, player: AudioPlayer, playbackClock: PlaybackClock) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playbackClock = playbackClock
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.register(IOSInlineTextFieldCell.self, forCellReuseIdentifier: "TextField")
        tableView.register(IOSSwitchCell.self, forCellReuseIdentifier: "Switch")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStorageUsage()
        tableView.reloadData()
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
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .runtime:
            return 2
        case .backend:
            return 2
        case .playback:
            return 2
        case .reader:
            return 7
        case .storage:
            return 8
        case .advanced:
            return 4
        case .about:
            return 3
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .runtime:
            return L10n.string("settings.audioEngine")
        case .backend:
            return L10n.string("settings.remoteBackend")
        case .playback:
            return L10n.string("settings.playback")
        case .reader:
            return L10n.string("settings.reader")
        case .storage:
            return L10n.string("settings.storage")
        case .advanced:
            return L10n.string("settings.advanced")
        case .about:
            return L10n.string("settings.about")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .runtime:
            return L10n.string("settings.audioEngineFooter")
        case .backend:
            return settings.remoteBackendControlsEnabled ? L10n.string("settings.remoteBackendFooterIOS") : nil
        case .playback:
            return L10n.string("settings.playbackFooter")
        case .reader:
            return L10n.string("settings.readerFooter")
        case .storage:
            return L10n.string("settings.storageFooter")
        case .advanced:
            return nil
        case .about:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else { return UITableViewCell() }
        switch section {
        case .runtime:
            if indexPath.row == 1 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
                cell.configure(
                    title: L10n.string("settings.allowCellularAudio"),
                    subtitle: L10n.string("settings.allowCellularAudioDescription"),
                    isOn: settings.allowCellularAudioConversion
                )
                cell.onValueChanged = { [weak self] isOn in
                    self?.settings.allowCellularAudioConversion = isOn
                    LocalAudioConversionScheduler.shared.setAllowsCellularConversion(isOn)
                }
                cell.accessibilityIdentifier = "settings.allowCellularAudio"
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
            cell.configure(
                title: L10n.string("settings.useBuiltInEngine"),
                subtitle: L10n.string("settings.useBuiltInEngineDescription"),
                isOn: settings.useEmbeddedRuntime
            )
            cell.onValueChanged = { [weak self] isOn in
                self?.settings.useEmbeddedRuntime = isOn
                self?.tableView.reloadSections(IndexSet(integer: Section.backend.rawValue), with: .none)
            }
            return cell
        case .backend:
            if indexPath.row == 0 {
                let cell = tableView.dequeueReusableCell(withIdentifier: "TextField", for: indexPath) as! IOSInlineTextFieldCell
                cell.configure(
                    title: L10n.string("settings.url"),
                    value: settings.backendURL,
                    placeholder: "http://localhost:8000",
                    keyboardType: .URL,
                    autocapitalization: .none,
                    isEnabled: settings.remoteBackendControlsEnabled
                )
                cell.onTextChanged = { [weak self] text in self?.settings.backendURL = text }
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("settings.urlNotValid")
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemRed
            cell.contentConfiguration = content
            let showWarning = settings.remoteBackendControlsEnabled && settings.resolvedBaseURL == nil
            cell.isHidden = !showWarning
            cell.selectionStyle = .none
            return cell
        case .reader:
            return readerCell(for: indexPath)
        case .playback:
            return playbackCell(for: indexPath)
        case .storage:
            return storageCell(for: indexPath)
        case .advanced:
            return advancedCell(for: indexPath)
        case .about:
            return aboutCell(for: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .reader:
            handleReaderSelection(row: indexPath.row)
        case .playback:
            handlePlaybackSelection(row: indexPath.row)
        case .storage:
            handleStorageSelection(row: indexPath.row)
        case .advanced:
            handleAdvancedSelection(row: indexPath.row)
        case .about:
            handleAboutSelection(row: indexPath.row)
        case .runtime, .backend:
            break
        }
    }

    private func playbackCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = indexPath.row == 0
            ? L10n.string("settings.skipForward")
            : L10n.string("settings.skipBackward")
        let seconds = indexPath.row == 0 ? settings.playbackForwardSeconds : settings.playbackBackwardSeconds
        content.secondaryText = L10n.string("settings.seconds", Int(seconds))
        content.image = UIImage(systemName: indexPath.row == 0 ? "goforward" : "gobackward")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = indexPath.row == 0 ? "settings.skipForward" : "settings.skipBackward"
        return cell
    }

    private func handlePlaybackSelection(row: Int) {
        let forward = row == 0
        presentChoice(
            title: forward ? L10n.string("settings.skipForward") : L10n.string("settings.skipBackward"),
            options: [15, 30, 45, 60].map { (L10n.string("settings.seconds", $0), Double($0)) },
            currentValue: forward ? settings.playbackForwardSeconds : settings.playbackBackwardSeconds
        ) { [weak self] value in
            guard let self else { return }
            if forward {
                self.settings.playbackForwardSeconds = value
            } else {
                self.settings.playbackBackwardSeconds = value
            }
            self.player.refreshRemoteSkipIntervals()
            self.tableView.reloadSections(IndexSet(integer: Section.playback.rawValue), with: .none)
        }
    }

    private func readerCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.fontSize")
            content.secondaryText = L10n.string("settings.fontStep", settings.readerFontSize + 1, 5)
            content.image = UIImage(systemName: "textformat.size")
        case 1:
            content.text = L10n.string("settings.font")
            content.secondaryText = settings.readerFontFamily.displayName
            content.image = UIImage(systemName: "textformat")
        case 2:
            content.text = L10n.string("settings.theme")
            content.secondaryText = settings.readerTheme.displayName
            content.image = UIImage(systemName: "paintpalette")
        case 3:
            content.text = L10n.string("settings.layout")
            content.secondaryText = settings.readerLayout.displayName
            content.image = UIImage(systemName: "doc.text")
        case 4:
            content.text = L10n.string("settings.lineSpacing")
            content.secondaryText = "\(Int(settings.readerLineSpacing)) pt"
            content.image = UIImage(systemName: "arrow.up.and.down.text.horizontal")
        case 5:
            content.text = L10n.string("settings.margin")
            content.secondaryText = "\(Int(settings.readerMargin)) pt"
            content.image = UIImage(systemName: "rectangle.compress.vertical")
        default:
            content.text = L10n.string("settings.autoScroll")
            content.secondaryText = nil
            content.image = UIImage(systemName: "arrow.down.to.line")
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText
        cell.accessibilityHint = indexPath.row == 6
            ? L10n.string("settings.autoScrollHint")
            : L10n.string("settings.openOptionHint")
        if indexPath.row == 6 {
            cell.accessoryType = settings.readerAutoScroll ? .checkmark : .none
        }
        return cell
    }

    private func storageCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = nil
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.storageUsage")
            content.secondaryText = "\(formatBytes(storageUsage.totalBytes)) / \(formatBytes(storageUsage.budgetBytes))"
            content.image = UIImage(systemName: "internaldrive")
            cell.selectionStyle = .none
        case 1:
            content.text = L10n.string("settings.offlineAudio")
            content.secondaryText = formatBytes(storageUsage.offlineAudioBytes)
            cell.selectionStyle = .none
        case 2:
            content.text = L10n.string("settings.ttsCache")
            content.secondaryText = formatBytes(storageUsage.ttsCacheBytes)
            cell.selectionStyle = .none
        case 3:
            content.text = L10n.string("settings.storageTotal")
            content.secondaryText = formatBytes(storageUsage.totalBytes)
            cell.selectionStyle = .none
        case 4:
            content.text = L10n.string("settings.manageDownloads")
            content.secondaryText = L10n.string("settings.manageDownloadsDescription")
            content.image = UIImage(systemName: "books.vertical")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "settings.manageDownloads"
        case 5:
            content.text = L10n.string("settings.refreshStorage")
            content.image = UIImage(systemName: "arrow.clockwise")
        case 6:
            content.text = L10n.string("settings.clearTemporaryAudio")
            content.image = UIImage(systemName: "trash")
            content.textProperties.color = .systemRed
        default:
            content.text = L10n.string("settings.clearAllDownloads")
            content.image = UIImage(systemName: "trash")
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

    private func advancedCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = nil
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.recentJobs")
            content.secondaryText = L10n.string("settings.recentJobsDescription")
            content.image = UIImage(systemName: "clock.arrow.circlepath")
        case 1:
            content.text = L10n.string("settings.telemetry")
            content.secondaryText = L10n.string("settings.telemetryDescription")
            content.image = UIImage(systemName: "speedometer")
        case 2:
            content.text = L10n.string("settings.exportPerformanceDiagnostics")
            content.secondaryText = L10n.string("settings.exportPerformanceDiagnosticsDescription")
            content.image = UIImage(systemName: "square.and.arrow.up")
            cell.accessibilityIdentifier = "settings.exportPerformanceDiagnostics"
        default:
            content.text = L10n.string("settings.clearCache")
            content.secondaryText = L10n.string("settings.clearCacheDescription")
            content.textProperties.color = .systemRed
            content.image = UIImage(systemName: "trash")
            cell.accessoryType = .none
        }
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        return cell
    }

    private func aboutCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.bundleIdentifier")
            content.secondaryText = "com.pietrocode.epubtomp3"
            cell.selectionStyle = .none
        case 1:
            content.text = L10n.string("settings.platform")
            content.secondaryText = Self.platformMinimumLabel
            cell.selectionStyle = .none
        default:
            content.text = L10n.string("settings.projectOnGithub")
            content.image = UIImage(systemName: "arrow.up.right.square")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        return cell
    }

    private func handleReaderSelection(row: Int) {
        switch row {
        case 0:
            presentChoice(
                title: L10n.string("settings.fontSize"),
                options: (0...4).map { (L10n.string("settings.fontStep", $0 + 1, 5), $0) },
                currentValue: settings.readerFontSize
            ) { [weak self] value in
                self?.settings.readerFontSize = value
            }
        case 1:
            presentChoice(
                title: L10n.string("settings.font"),
                options: ReaderFontFamily.allCases.map { ($0.displayName, $0) },
                currentValue: settings.readerFontFamily
            ) { [weak self] value in
                self?.settings.readerFontFamily = value
            }
        case 2:
            presentChoice(
                title: L10n.string("settings.theme"),
                options: ReaderTheme.allCases.map { ($0.displayName, $0) },
                currentValue: settings.readerTheme
            ) { [weak self] value in
                self?.settings.readerTheme = value
            }
        case 3:
            presentChoice(
                title: L10n.string("settings.layout"),
                options: ReaderLayout.allCases.map { ($0.displayName, $0) },
                currentValue: settings.readerLayout
            ) { [weak self] value in
                self?.settings.readerLayout = value
            }
        case 4:
            presentChoice(
                title: L10n.string("settings.lineSpacing"),
                options: stride(from: 0, through: 16, by: 2).map { ("\($0) pt", Double($0)) },
                currentValue: settings.readerLineSpacing
            ) { [weak self] value in
                self?.settings.readerLineSpacing = value
            }
        case 5:
            presentChoice(
                title: L10n.string("settings.margin"),
                options: stride(from: 16, through: 80, by: 4).map { ("\($0) pt", Double($0)) },
                currentValue: settings.readerMargin
            ) { [weak self] value in
                self?.settings.readerMargin = value
            }
        default:
            settings.readerAutoScroll.toggle()
        }
        tableView.reloadSections(IndexSet(integer: Section.reader.rawValue), with: .none)
    }

    private func handleStorageSelection(row: Int) {
        if row == 4 {
            navigationController?.pushViewController(
                LocalAudioDownloadsScreenController(library: library),
                animated: true
            )
        } else if row == 5 {
            refreshStorageUsage()
            tableView.reloadSections(IndexSet(integer: Section.storage.rawValue), with: .none)
        } else if row == 6 {
            presentDestructiveAlert(
                title: L10n.string("settings.clearTemporaryAudioConfirmTitle"),
                message: L10n.string("settings.clearTemporaryAudioConfirmMessage"),
                buttonTitle: L10n.string("settings.clearCacheConfirmButton")
            ) { [weak self] in
                self?.clearTemporaryAudio()
            }
        } else if row == 6 {
            presentDestructiveAlert(
                title: L10n.string("settings.clearAllDownloadsConfirmTitle"),
                message: L10n.string("settings.clearAllDownloadsConfirmMessage"),
                buttonTitle: L10n.string("settings.clearCacheConfirmButton")
            ) { [weak self] in
                self?.clearAllDownloads()
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
        } else {
            presentDestructiveAlert(
                title: L10n.string("settings.clearCacheConfirmTitle"),
                message: L10n.string("settings.clearCacheConfirmMessage"),
                buttonTitle: L10n.string("settings.clearCacheConfirmButton")
            ) { [weak self] in
                self?.clearAllDownloads()
                self?.presentInfoAlert(title: L10n.string("settings.clearCacheDone"))
            }
        }
    }

    private func exportPerformanceDiagnostics() {
        do {
            let url = try LatencyObservationStore.shared.writeDiagnosticExport()
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = view.bounds
            }
            present(controller, animated: true)
        } catch {
            presentInfoAlert(
                title: L10n.string("settings.exportPerformanceDiagnostics"),
                message: L10n.string("settings.exportPerformanceDiagnosticsError")
            )
        }
    }

    private func handleAboutSelection(row: Int) {
        guard row == 2, let url = URL(string: "https://github.com/pietro1704/Epub-to-Mp3") else { return }
        UIApplication.shared.open(url)
    }

    private func refreshStorageUsage() {
        storageUsage = StorageUsageScanner.current(budgetBytes: settings.offlineCacheBudgetBytes)
    }

    private func clearAllDownloads() {
        Task { [weak self] in
            guard let self else { return }
            await DownloadManager.shared.cancelAll()
            try? await LocalAudioArtifactStore.shared.clearAllAudio()
            StorageUsageScanner.clearAllDownloads()
            for var book in self.library.books where book.cachedOffline {
                book.cachedOffline = false
                self.library.update(book)
            }
            self.refreshStorageUsage()
            self.tableView.reloadSections(IndexSet(integer: Section.storage.rawValue), with: .none)
        }
    }

    private func clearTemporaryAudio() {
        Task { [weak self] in
            StorageUsageScanner.clearLegacyTemporaryAudio()
            try? await LocalAudioArtifactStore.shared.clearTemporaryAudio()
            guard let self else { return }
            self.refreshStorageUsage()
            self.tableView.reloadSections(IndexSet(integer: Section.storage.rawValue), with: .none)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func presentInfoAlert(title: String, message: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("library.ok"), style: .default))
        present(alert, animated: true)
    }

    private func presentDestructiveAlert(
        title: String,
        message: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: buttonTitle, style: .destructive) { _ in action() })
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func presentChoice<Value: Equatable>(
        title: String,
        options: [(String, Value)],
        currentValue: Value,
        apply: @escaping (Value) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (label, value) in options {
            let suffix = value == currentValue ? " ✓" : ""
            alert.addAction(UIAlertAction(title: label + suffix, style: .default) { _ in
                apply(value)
                self.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("library.cancel"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        present(alert, animated: true)
    }
}
#endif
