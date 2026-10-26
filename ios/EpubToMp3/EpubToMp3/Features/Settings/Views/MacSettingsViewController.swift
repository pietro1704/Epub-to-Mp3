#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacSettingsViewController: NSViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let clearDownloadsOperation: () async throws -> Void
    private let speechModels: SpeechModelLibraryClient
    private var speechModelState: SpeechModelLibraryViewState
    private var speechModelsTask: Task<Void, Never>?
    private var speechModelInstallTask: Task<Void, Never>?
    private var speechModelInstallEvent: SpeechModelInstallEvent?
    private var isClearingDownloads = false
    private let fontSizeStepper = NSStepper()
    private let fontSizeLabel = NSTextField(labelWithString: "")
    private let fontPopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let layoutPopup = NSPopUpButton()
    private let audioEnginePopup = NSPopUpButton()
    private var narrationSelections: [TtsSelection] = []
    private let secondaryEnginePopup = NSPopUpButton()
    private let onlineFallbackButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let piperInstallButton = NSButton()
    private let piperModelLabel = NSTextField(wrappingLabelWithString: "")
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
         speechModels: SpeechModelLibraryClient = .shared) {
        self.settings = settings
        self.library = library
        self.speechModels = speechModels
        self.speechModelState = SpeechModelLibraryViewState(snapshot: speechModels.initialSnapshot)
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
        reloadSpeechModels()
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

    deinit {
        diagnosticsExpiryTask?.cancel()
        speechModelsTask?.cancel()
        speechModelInstallTask?.cancel()
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
        audioEnginePopup.target = self
        audioEnginePopup.action = #selector(audioEngineChanged(_:))
        secondaryEnginePopup.menu?.autoenablesItems = false
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
        clearButton.setAccessibilityLabel(L10n.string("settings.clearAllDownloads"))
        refreshButton.setAccessibilityLabel(L10n.string("settings.refreshStorage"))
        exportDiagnosticsButton.setAccessibilityLabel(L10n.string("settings.exportPerformanceDiagnostics"))
        func row(_ label: String, _ control: NSView) -> [NSView] {
            let title = NSTextField(wrappingLabelWithString: label)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return [title, control]
        }
        let audioEngineRows: [[NSView]] = AudioEnginePreference.supportedPreferences.contains(.piper)
            ? [row(L10n.string("settings.audioEngineChoice"), audioEnginePopup), [piperModelLabel, piperInstallButton], row(L10n.string("settings.secondaryVoice"), secondaryEnginePopup), row(L10n.string("settings.onlineFallbackDescription"), onlineFallbackButton)]
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
        rebuildNarrationChoices()
    }

    private func refresh() {
        fontSizeStepper.integerValue = settings.readerFontSize
        fontSizeLabel.stringValue = L10n.string("settings.fontStep", settings.readerFontSize + 1, 5)
        selectItem(at: ReaderFontFamily.allCases.firstIndex(of: settings.readerFontFamily) ?? 0,
                   in: fontPopup)
        selectItem(at: ReaderTheme.allCases.firstIndex(of: settings.readerTheme) ?? 0,
                   in: themePopup)
        selectItem(at: ReaderLayout.allCases.firstIndex(of: settings.readerLayout) ?? 0,
                   in: layoutPopup)
        selectItem(at: narrationSelections.firstIndex(of: settings.ttsPreferences.primary) ?? 0,
                   in: audioEnginePopup)
        selectItem(at: settings.ttsPreferences.secondary
            .flatMap { narrationSelections.firstIndex(of: $0) }.map { $0 + 1 } ?? 0,
            in: secondaryEnginePopup)
        for (index, selection) in narrationSelections.enumerated() {
            secondaryEnginePopup.item(at: index + 1)?.isEnabled = !selection.representsSameRequest(as: settings.ttsPreferences.primary) && (selection.engine != "edge" || settings.allowOnlineAudioFallback)
        }
        onlineFallbackButton.state = settings.allowOnlineAudioFallback ? .on : .off
        if let entry = speechModelState.defaultEntry {
            piperModelLabel.stringValue = speechModelState.displayName(for: entry)
            piperInstallButton.title = speechModelState.installActionTitle(
                for: entry,
                event: speechModelInstallEvent
            )
            piperInstallButton.toolTip = speechModelInstallEvent
                .map(speechModelState.installStatus(for:)) ?? speechModelState.status(for: entry)
            piperInstallButton.isEnabled = entry.distribution.installable
                && (entry.installation.state != .installed || speechModelInstallEvent?.isActive == true)
        } else {
            piperModelLabel.stringValue = AudioEnginePreference.piper.displayName
            piperInstallButton.title = L10n.string("settings.modelInstall", AudioEnginePreference.piper.displayName)
            piperInstallButton.toolTip = L10n.string("settings.modelState.notInspected")
            piperInstallButton.isEnabled = false
        }
        piperInstallButton.setAccessibilityLabel(piperInstallButton.title)
        piperInstallButton.setAccessibilityValue(piperInstallButton.toolTip)
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
        guard narrationSelections.indices.contains(sender.indexOfSelectedItem) else { return }
        settings.selectPrimaryNarration(narrationSelections[sender.indexOfSelectedItem])
        refresh()
    }

    @objc private func secondaryEngineChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard narrationSelections.indices.contains(index) else {
            settings.selectSecondaryNarration(nil)
            return
        }
        let selection = narrationSelections[index]
        guard !selection.representsSameRequest(as: settings.ttsPreferences.primary) && (selection.engine != "edge" || settings.allowOnlineAudioFallback) else {
            refresh()
            return
        }
        settings.selectSecondaryNarration(selection)
    }
    @objc private func onlineFallbackChanged(_ sender: NSButton) {
        settings.allowOnlineAudioFallback = sender.state == .on
        refresh()
    }

    @objc private func installPiperModel() {
        guard let entry = speechModelState.defaultEntry,
              entry.distribution.installable else { return }
        if speechModelInstallEvent?.isActive == true {
            Task { await speechModels.cancelInstall(modelID: entry.identity.modelID) }
            return
        }
        guard entry.installation.state != .installed else { return }
        let title = speechModelState.installTitle(for: entry)
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await speechModels.install(modelID: entry.identity.modelID)
                let snapshot = try await speechModels.snapshot()
                speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                rebuildNarrationChoices()
            } catch is CancellationError {
                // Cancellation is already rendered by the operation event.
            } catch {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = AppErrorReporter.message(error, context: #function)
                alert.addButton(withTitle: L10n.string("common.ok"))
                alert.runModal()
            }
            self.refresh()
        }
    }

    private func rebuildNarrationChoices() {
        let catalogChoices = speechModelState.selectableChoices.map(\.selection)
        narrationSelections = AudioEnginePreference.supportedPreferences.flatMap { engine -> [TtsSelection] in
            let matching = catalogChoices.filter { $0.engine == engine.rawValue }
            return matching.isEmpty ? [.selected(engine)] : matching
        }
        for selection in [settings.primaryTtsSelection, settings.secondaryTtsSelection].compactMap({ $0 })
            where !narrationSelections.contains(selection) {
            narrationSelections.append(selection)
        }
        let titles = narrationSelections.map(speechModelState.displayName(for:))
        audioEnginePopup.removeAllItems()
        audioEnginePopup.addItems(withTitles: titles)
        secondaryEnginePopup.removeAllItems()
        secondaryEnginePopup.addItems(withTitles: [L10n.string("settings.noSecondary")] + titles)
    }

    private func selectItem(at index: Int, in popup: NSPopUpButton) {
        guard index >= 0, index < popup.numberOfItems else { return }
        popup.selectItem(at: index)
    }

    private func reloadSpeechModels() {
        speechModelsTask?.cancel()
        speechModelsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await speechModels.snapshot()
                guard !Task.isCancelled else { return }
                speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                observeInstall(modelID: snapshot.defaultSelection.modelID)
                rebuildNarrationChoices()
                refresh()
            } catch {
                // Fail closed: keep existing selections and the last valid presentation.
            }
        }
    }

    private func observeInstall(modelID: String?) {
        speechModelInstallTask?.cancel()
        guard let modelID else { return }
        speechModelInstallTask = Task { [weak self] in
            guard let self else { return }
            let events = await speechModels.watchInstall(modelID: modelID)
            for await event in events {
                guard !Task.isCancelled else { return }
                speechModelInstallEvent = event
                if event.stage == .completed,
                   let snapshot = try? await speechModels.snapshot() {
                    speechModelState = SpeechModelLibraryViewState(snapshot: snapshot)
                    rebuildNarrationChoices()
                }
                refresh()
            }
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
                AppErrorReporter.message(error, context: "Diagnostics export")
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
                let message = AppErrorReporter.message(error, context: "Download removal")
                guard let window = view.window else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = L10n.string("settings.storageRemovalFailedTitle")
                alert.informativeText = L10n.string("settings.storageRemovalFailedMessage")
                    + "\n\n" + message
                alert.addButton(withTitle: L10n.string("library.ok"))
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }
}
#endif
