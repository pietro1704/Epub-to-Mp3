#if os(iOS)
import UIKit

@MainActor
final class SettingsScreenController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case runtime
        case backend
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
            return 1
        case .backend:
            return 2
        case .reader:
            return 7
        case .storage:
            return 6
        case .advanced:
            return 3
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

    private func readerCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.fontSize")
            content.secondaryText = "\(settings.readerFontSize + 1) of 5"
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
        if indexPath.row == 6 {
            cell.accessoryType = settings.readerAutoScroll ? .checkmark : .none
        }
        return cell
    }

    private func storageCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryType = .none
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
            content.text = L10n.string("settings.refreshStorage")
            content.image = UIImage(systemName: "arrow.clockwise")
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
        switch indexPath.row {
        case 0:
            content.text = L10n.string("settings.recentJobs")
            content.secondaryText = L10n.string("settings.recentJobsDescription")
            content.image = UIImage(systemName: "clock.arrow.circlepath")
        case 1:
            content.text = L10n.string("settings.telemetry")
            content.secondaryText = L10n.string("settings.telemetryDescription")
            content.image = UIImage(systemName: "speedometer")
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
            content.secondaryText = SettingsView.platformMinimumLabel
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
                options: (0...4).map { ("\($0 + 1) of 5", $0) },
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
            refreshStorageUsage()
            tableView.reloadSections(IndexSet(integer: Section.storage.rawValue), with: .none)
        } else if row == 5 {
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

    private func handleAboutSelection(row: Int) {
        guard row == 2, let url = URL(string: "https://github.com/pietro1704/Epub-to-Mp3") else { return }
        UIApplication.shared.open(url)
    }

    private func refreshStorageUsage() {
        storageUsage = StorageUsageScanner.current(budgetBytes: settings.offlineCacheBudgetBytes)
    }

    private func clearAllDownloads() {
        Task { await DownloadManager.shared.cancelAll() }
        StorageUsageScanner.clearAllDownloads()
        for var book in library.books where book.cachedOffline {
            book.cachedOffline = false
            library.update(book)
        }
        refreshStorageUsage()
        tableView.reloadSections(IndexSet(integer: Section.storage.rawValue), with: .none)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private func presentInfoAlert(title: String) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
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
