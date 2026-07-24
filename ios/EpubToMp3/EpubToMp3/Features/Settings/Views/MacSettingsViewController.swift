#if os(macOS)
import AppKit

@MainActor
final class MacSettingsViewController: NSViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let sidecar: SidecarManager
    private let embeddedServerSwitch = NSSwitch()
    private let backendField = NSTextField()
    private let fontSizeStepper = NSStepper()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let fontPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let layoutPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let storageLabel = NSTextField(labelWithString: "")

    init(settings: AppSettings, library: LibraryStore, sidecar: SidecarManager) {
        self.settings = settings
        self.library = library
        self.sidecar = sidecar
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("settings.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureControls()
        refresh()
    }

    private func configureControls() {
        embeddedServerSwitch.target = self
        embeddedServerSwitch.action = #selector(embeddedServerChanged(_:))
        backendField.placeholderString = "http://localhost:8000"
        backendField.target = self
        backendField.action = #selector(backendChanged(_:))
        fontSizeStepper.minValue = 0
        fontSizeStepper.maxValue = 4
        fontSizeStepper.increment = 1
        fontSizeStepper.target = self
        fontSizeStepper.action = #selector(fontSizeChanged(_:))
        fontPopup.addItems(withTitles: ReaderFontFamily.allCases.map(\.displayName))
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        themePopup.addItems(withTitles: ReaderTheme.allCases.map(\.displayName))
        themePopup.target = self
        themePopup.action = #selector(themeChanged(_:))
        layoutPopup.addItems(withTitles: ReaderLayout.allCases.map(\.displayName))
        layoutPopup.target = self
        layoutPopup.action = #selector(layoutChanged(_:))
        statusLabel.textColor = .secondaryLabelColor
        storageLabel.textColor = .secondaryLabelColor

        let clearButton = NSButton(title: L10n.string("settings.clearAllDownloads"),
                                   target: self,
                                   action: #selector(clearDownloads))
        let refreshButton = NSButton(title: L10n.string("settings.refreshStorage"),
                                     target: self,
                                     action: #selector(refreshStorage))
        let form = NSForm()
        form.addRow(withIdentifier: "runtime", label: L10n.string("settings.useEmbeddedServer"), view: embeddedServerSwitch)
        form.addRow(withIdentifier: "status", label: L10n.string("settings.embeddedServer"), view: statusLabel)
        form.addRow(withIdentifier: "backend", label: L10n.string("settings.url"), view: backendField)
        form.addRow(withIdentifier: "fontSize", label: L10n.string("settings.fontSize"), view: fontSizeStepper)
        form.addRow(withIdentifier: "fontSizeValue", label: "", view: fontSizeLabel)
        form.addRow(withIdentifier: "font", label: L10n.string("settings.font"), view: fontPopup)
        form.addRow(withIdentifier: "theme", label: L10n.string("settings.theme"), view: themePopup)
        form.addRow(withIdentifier: "layout", label: L10n.string("settings.layout"), view: layoutPopup)
        form.addRow(withIdentifier: "storage", label: L10n.string("settings.storageUsage"), view: storageLabel)
        form.addRow(withIdentifier: "refresh", label: "", view: refreshButton)
        form.addRow(withIdentifier: "clear", label: "", view: clearButton)
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            form.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            form.widthAnchor.constraint(equalToConstant: 620),
        ])
    }

    private func refresh() {
        embeddedServerSwitch.state = settings.useEmbeddedSidecar ? .on : .off
        backendField.stringValue = settings.backendURL
        fontSizeStepper.integerValue = settings.readerFontSize
        fontSizeLabel.stringValue = "\(settings.readerFontSize + 1) of 5"
        fontPopup.selectItem(at: ReaderFontFamily.allCases.firstIndex(of: settings.readerFontFamily) ?? 0)
        themePopup.selectItem(at: ReaderTheme.allCases.firstIndex(of: settings.readerTheme) ?? 0)
        layoutPopup.selectItem(at: ReaderLayout.allCases.firstIndex(of: settings.readerLayout) ?? 0)
        statusLabel.stringValue = sidecarStatusLabel
        storageLabel.stringValue = formatStorage(StorageUsageScanner.current(budgetBytes: settings.offlineCacheBudgetBytes))
    }

    private var sidecarStatusLabel: String {
        switch sidecar.state {
        case .idle: return L10n.string("settings.sidecar.idle")
        case .starting: return L10n.string("settings.sidecar.starting")
        case .running(let url): return L10n.string("settings.sidecar.running") + " (\(url.absoluteString))"
        case .failed(let error): return L10n.string("settings.sidecar.failed", String(error.prefix(120)))
        case .unsupported: return L10n.string("settings.sidecar.unsupported")
        }
    }

    private func formatStorage(_ usage: StorageUsageSnapshot) -> String {
        "\(ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)) / "
            + ByteCountFormatter.string(fromByteCount: usage.budgetBytes, countStyle: .file)
    }

    @objc private func embeddedServerChanged(_ sender: NSSwitch) {
        settings.useEmbeddedSidecar = sender.state == .on
        refresh()
    }

    @objc private func backendChanged(_ sender: NSTextField) { settings.backendURL = sender.stringValue }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        settings.readerFontSize = sender.integerValue
        fontSizeLabel.stringValue = "\(sender.integerValue + 1) of 5"
    }

    @objc private func fontChanged(_ sender: NSPopUpButton) {
        settings.readerFontFamily = ReaderFontFamily.allCases[sender.indexOfSelectedItem]
    }

    @objc private func themeChanged(_ sender: NSPopUpButton) {
        settings.readerTheme = ReaderTheme.allCases[sender.indexOfSelectedItem]
    }

    @objc private func layoutChanged(_ sender: NSPopUpButton) {
        settings.readerLayout = ReaderLayout.allCases[sender.indexOfSelectedItem]
    }

    @objc private func refreshStorage() { refresh() }

    @objc private func clearDownloads() {
        Task { await DownloadManager.shared.cancelAll() }
        StorageUsageScanner.clearAllDownloads()
        for var book in library.books where book.cachedOffline {
            book.cachedOffline = false
            library.update(book)
        }
        refresh()
    }
}
#endif
