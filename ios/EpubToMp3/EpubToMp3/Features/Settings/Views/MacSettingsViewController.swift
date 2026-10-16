#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacSettingsViewController: NSViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let clearDownloadsOperation: () async throws -> Void
    private let installPiperModelOperation: @Sendable (String, String) throws -> URL
    private var isClearingDownloads = false
    private let fontSizeStepper = NSStepper()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let fontPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let layoutPopup = NSPopUpButton()
    private let audioEnginePopup = NSPopUpButton()
    private let secondaryEnginePopup = NSPopUpButton()
    private let onlineFallbackButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let piperInstallButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let storageLabel = NSTextField(labelWithString: "")
    private let diagnosticsButton = NSButton()
    private let diagnosticsLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticsSession: StreamingDiagnosticsSession
    private let confirmStreamingDiagnostics: ((String, String, @escaping () -> Void) -> Void)?
    private var diagnosticsExpiryTask: Task<Void, Never>?

    init(settings: AppSettings, library: LibraryStore,
         diagnosticsSession: StreamingDiagnosticsSession? = nil,
         confirmStreamingDiagnostics: ((String, String, @escaping () -> Void) -> Void)? = nil,
         clearDownloadsOperation: (() async throws -> Void)? = nil,
         installPiperModelOperation: @escaping @Sendable (String, String) throws -> URL = { modelID, root in
             try ConverterFFIAdapter().installTtsModelFromCatalog(modelID: modelID, root: root)
         }) {
        self.settings = settings
        self.library = library
        self.installPiperModelOperation = installPiperModelOperation
        self.clearDownloadsOperation = clearDownloadsOperation ?? {
            try await AudioStorageMaintenance().clearAllDownloads()
        }
        self.diagnosticsSession = diagnosticsSession ?? .shared
        self.confirmStreamingDiagnostics = confirmStreamingDiagnostics
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
        refreshStreamingDiagnostics()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refreshStreamingDiagnostics()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        diagnosticsExpiryTask?.cancel()
        diagnosticsExpiryTask = nil
    }

    deinit { diagnosticsExpiryTask?.cancel() }

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
        audioEnginePopup.addItems(withTitles: AudioEnginePreference.supportedPreferences.map(\.displayName))
        audioEnginePopup.target = self
        audioEnginePopup.action = #selector(audioEngineChanged(_:))
        secondaryEnginePopup.addItems(withTitles: [L10n.string("settings.noSecondary")] + AudioEnginePreference.supportedPreferences.map(\.displayName))
        secondaryEnginePopup.target = self
        secondaryEnginePopup.action = #selector(secondaryEngineChanged(_:))
        onlineFallbackButton.title = L10n.string("settings.onlineFallback")
        onlineFallbackButton.target = self
        onlineFallbackButton.action = #selector(onlineFallbackChanged(_:))
        secondaryEnginePopup.setAccessibilityLabel(L10n.string("settings.secondaryVoice"))
        audioEnginePopup.setAccessibilityIdentifier("settings.tts.primary")
        secondaryEnginePopup.setAccessibilityIdentifier("settings.tts.secondary")
        onlineFallbackButton.setAccessibilityIdentifier("settings.tts.onlineConsent")
        piperInstallButton.target = self
        piperInstallButton.action = #selector(installPiperModel)
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
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(toggleStreamingDiagnostics)
        diagnosticsButton.setAccessibilityIdentifier("settings.recordStreamingDiagnostics")
        diagnosticsLabel.setAccessibilityIdentifier("settings.streamingDiagnosticsStatus")
        fontSizeStepper.setAccessibilityLabel(L10n.string("settings.fontSize"))
        fontPopup.setAccessibilityLabel(L10n.string("settings.font"))
        themePopup.setAccessibilityLabel(L10n.string("settings.theme"))
        layoutPopup.setAccessibilityLabel(L10n.string("settings.layout"))
        audioEnginePopup.setAccessibilityLabel(L10n.string("settings.audioEngineChoice"))
        piperInstallButton.setAccessibilityLabel(L10n.string("settings.piperInstall"))
        clearButton.setAccessibilityLabel(L10n.string("settings.clearAllDownloads"))
        refreshButton.setAccessibilityLabel(L10n.string("settings.refreshStorage"))
        exportDiagnosticsButton.setAccessibilityLabel(L10n.string("settings.exportPerformanceDiagnostics"))
        func row(_ label: String, _ control: NSView) -> [NSView] {
            let title = NSTextField(wrappingLabelWithString: label)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [title, control]
        }
        let audioEngineRows: [[NSView]] = AudioEnginePreference.supportedPreferences.contains(.piper)
            ? [row(L10n.string("settings.audioEngineChoice"), audioEnginePopup), row("Faber medium", piperInstallButton), row(L10n.string("settings.secondaryVoice"), secondaryEnginePopup), row(L10n.string("settings.onlineFallbackDescription"), onlineFallbackButton)]
            : [row(L10n.string("settings.audioEngineChoice"), audioEnginePopup)]
        let sizeControl = NSStackView(views: [fontSizeStepper, fontSizeLabel])
        sizeControl.spacing = 8
        sizeControl.alignment = .centerY
        let rows = [row(L10n.string("settings.embeddedServer"), statusLabel)] + audioEngineRows + [
            row(L10n.string("settings.fontSize"), sizeControl),
            row(L10n.string("settings.font"), fontPopup),
            row(L10n.string("settings.theme"), themePopup),
            row(L10n.string("settings.layout"), layoutPopup),
            row(L10n.string("settings.storageUsage"), storageLabel),
        ]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.yPlacement = .center
        grid.column(at: 0).width = 180
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        let form = NSStackView(views: [grid, refreshButton, exportDiagnosticsButton,
                                      diagnosticsButton, diagnosticsLabel, clearButton])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 16
        form.translatesAutoresizingMaskIntoConstraints = false
        grid.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        diagnosticsLabel.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        MacScrollableStack.install(form, in: view)

    }

    private func refresh() {
        fontSizeStepper.integerValue = settings.readerFontSize
        fontSizeLabel.stringValue = L10n.string("settings.fontStep", settings.readerFontSize + 1, 5)
        fontPopup.selectItem(at: ReaderFontFamily.allCases.firstIndex(of: settings.readerFontFamily) ?? 0)
        themePopup.selectItem(at: ReaderTheme.allCases.firstIndex(of: settings.readerTheme) ?? 0)
        layoutPopup.selectItem(at: ReaderLayout.allCases.firstIndex(of: settings.readerLayout) ?? 0)
        audioEnginePopup.selectItem(at: AudioEnginePreference.supportedPreferences.firstIndex(of: settings.audioEngine) ?? 0)
        secondaryEnginePopup.selectItem(at: settings.secondaryAudioEngine.flatMap { AudioEnginePreference.supportedPreferences.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        for (index, engine) in AudioEnginePreference.supportedPreferences.enumerated() {
            secondaryEnginePopup.item(at: index + 1)?.isEnabled = settings.selectableSecondaryAudioEngines.contains(engine)
        }
        onlineFallbackButton.state = settings.allowOnlineAudioFallback ? .on : .off
        piperInstallButton.title = AppSettings.isFaberInstalled() ? L10n.string("settings.piperInstalled") : L10n.string("settings.piperInstall")
        statusLabel.stringValue = embeddedRuntimeStatusLabel
        storageLabel.stringValue = formatStorage(StorageUsageScanner.current(budgetBytes: settings.offlineCacheBudgetBytes))
    }

    private var embeddedRuntimeStatusLabel: String {
        L10n.string("settings.embeddedRuntime.ready")
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

    @objc private func audioEngineChanged(_ sender: NSPopUpButton) {
        guard AudioEnginePreference.supportedPreferences.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.audioEngine = AudioEnginePreference.supportedPreferences[sender.indexOfSelectedItem]
        refresh()
    }

    @objc private func secondaryEngineChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard AudioEnginePreference.supportedPreferences.indices.contains(index) else {
            settings.secondaryAudioEngine = nil
            return
        }
        let engine = AudioEnginePreference.supportedPreferences[index]
        guard settings.selectableSecondaryAudioEngines.contains(engine) else {
            refresh()
            return
        }
        settings.secondaryAudioEngine = engine
    }
    @objc private func onlineFallbackChanged(_ sender: NSButton) {
        settings.allowOnlineAudioFallback = sender.state == .on
        refresh()
    }

    @objc private func installPiperModel() {
        guard let root = AppSettings.ttsModelsRoot() else { return }
        let install = installPiperModelOperation
        Task { [weak self] in
            let result = await Task.detached {
                Result { try install("pt_BR-faber-medium", root.path) }
            }.value
            guard let self else { return }
            if case .failure(let error) = result {
                let alert = NSAlert()
                alert.messageText = L10n.string("settings.piperInstall")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
            self.refresh()
        }
    }

    @objc private func refreshStorage() { refresh() }

    @objc private func exportPerformanceDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "performance-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                _ = try await LatencyObservationStore.shared.writeDiagnosticExport(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = L10n.string("settings.exportPerformanceDiagnostics")
                alert.informativeText = L10n.string("settings.exportPerformanceDiagnosticsError")
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
        }
    }

    @objc private func toggleStreamingDiagnostics() {
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
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: L10n.string("settings.enableStreamingDiagnostics"))
            alert.addButton(withTitle: L10n.string("common.cancel"))
            if let window = view.window {
                alert.beginSheetModal(for: window) { response in
                    if response == .alertFirstButtonReturn { enable() }
                }
            } else if alert.runModal() == .alertFirstButtonReturn {
                enable()
            }
        }
    }

    private func refreshStreamingDiagnostics() {
        let active = diagnosticsSession.isActive
        diagnosticsButton.title = L10n.string(active
            ? "settings.stopStreamingDiagnostics" : "settings.recordStreamingDiagnostics")
        diagnosticsButton.setAccessibilityLabel(diagnosticsButton.title)
        diagnosticsLabel.stringValue = L10n.string(active
            ? "settings.streamingDiagnosticsActive" : "settings.streamingDiagnosticsInactive")
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

    @objc private func clearDownloads() {
        guard !isClearingDownloads, let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("settings.clearAllDownloadsConfirmTitle")
        alert.informativeText = L10n.string("settings.clearAllDownloadsConfirmMessage")
        alert.addButton(withTitle: L10n.string("settings.clearAllDownloads"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.performDownloadRemoval()
        }
    }

    private func performDownloadRemoval() {
        guard !isClearingDownloads else { return }
        isClearingDownloads = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                isClearingDownloads = false
                refresh()
            }
            do {
                try await clearDownloadsOperation()
                for var book in library.books where book.cachedOffline {
                    book.cachedOffline = false
                    library.update(book)
                }
            } catch {
                guard let window = view.window else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.string("settings.storageRemovalFailedTitle")
                alert.informativeText = L10n.string("settings.storageRemovalFailedMessage")
                    + "\n\n" + error.localizedDescription
                alert.addButton(withTitle: L10n.string("library.ok"))
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
#endif
