#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacSettingsViewController: NSViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let fontSizeStepper = NSStepper()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let fontPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let layoutPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let storageLabel = NSTextField(labelWithString: "")

    init(settings: AppSettings, library: LibraryStore) {
        self.settings = settings
        self.library = library
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
        let exportDiagnosticsButton = NSButton(
            title: L10n.string("settings.exportPerformanceDiagnostics"),
            target: self,
            action: #selector(exportPerformanceDiagnostics)
        )
        fontSizeStepper.setAccessibilityLabel(L10n.string("settings.fontSize"))
        fontPopup.setAccessibilityLabel(L10n.string("settings.font"))
        themePopup.setAccessibilityLabel(L10n.string("settings.theme"))
        layoutPopup.setAccessibilityLabel(L10n.string("settings.layout"))
        clearButton.setAccessibilityLabel(L10n.string("settings.clearAllDownloads"))
        refreshButton.setAccessibilityLabel(L10n.string("settings.refreshStorage"))
        exportDiagnosticsButton.setAccessibilityLabel(L10n.string("settings.exportPerformanceDiagnostics"))
        func row(_ label: String, _ control: NSView) -> NSStackView {
            let title = NSTextField(labelWithString: label)
            title.setContentHuggingPriority(.required, for: .horizontal)
            let row = NSStackView(views: [title, control])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            return row
        }
        let form = NSStackView(views: [
            row(L10n.string("settings.embeddedServer"), statusLabel),
            row(L10n.string("settings.fontSize"), fontSizeStepper),
            row("", fontSizeLabel),
            row(L10n.string("settings.font"), fontPopup),
            row(L10n.string("settings.theme"), themePopup),
            row(L10n.string("settings.layout"), layoutPopup),
            row(L10n.string("settings.storageUsage"), storageLabel),
            row("", refreshButton),
            row("", exportDiagnosticsButton),
            row("", clearButton),
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = form
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 32),
            form.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -32),
            form.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 24),
            form.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor, constant: -24),
            form.widthAnchor.constraint(equalToConstant: 620),
        ])
    }

    private func refresh() {
        fontSizeStepper.integerValue = settings.readerFontSize
        fontSizeLabel.stringValue = L10n.string("settings.fontStep", settings.readerFontSize + 1, 5)
        fontPopup.selectItem(at: ReaderFontFamily.allCases.firstIndex(of: settings.readerFontFamily) ?? 0)
        themePopup.selectItem(at: ReaderTheme.allCases.firstIndex(of: settings.readerTheme) ?? 0)
        layoutPopup.selectItem(at: ReaderLayout.allCases.firstIndex(of: settings.readerLayout) ?? 0)
        statusLabel.stringValue = embeddedRuntimeStatusLabel
        storageLabel.stringValue = formatStorage(StorageUsageScanner.current(budgetBytes: settings.offlineCacheBudgetBytes))
    }

    private var embeddedRuntimeStatusLabel: String {
        PythonEmbed.shared.isBootstrapComplete
            ? L10n.string("settings.embeddedRuntime.ready")
            : L10n.string("settings.embeddedRuntime.starting")
    }

    private func formatStorage(_ usage: StorageUsageSnapshot) -> String {
        "\(ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)) / "
            + ByteCountFormatter.string(fromByteCount: usage.budgetBytes, countStyle: .file)
    }

    @objc private func fontSizeChanged(_ sender: NSStepper) {
        settings.readerFontSize = sender.integerValue
        fontSizeLabel.stringValue = L10n.string("settings.fontStep", sender.integerValue + 1, 5)
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

    @objc private func exportPerformanceDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "performance-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LatencyObservationStore.shared.exportData().write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.string("settings.exportPerformanceDiagnostics")
            alert.informativeText = L10n.string("settings.exportPerformanceDiagnosticsError")
            alert.addButton(withTitle: L10n.string("common.ok"))
            alert.runModal()
        }
    }

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
