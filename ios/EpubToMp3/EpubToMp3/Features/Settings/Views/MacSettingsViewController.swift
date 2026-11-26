#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class MacSettingsViewController: NSViewController {
    private let settings: AppSettings
    private let library: LibraryStore
    private let clearDownloadsOperation: () async throws -> Void
    private let speechModels: SpeechModelLibraryClient
    private let termsAcceptance: SpeechModelTermsAcceptanceStore
    private var voiceModelDestination: MacSettingsDetailNavigation?
    private var isClearingDownloads = false
    private let skipForwardPopup = NSPopUpButton()
    private let skipBackwardPopup = NSPopUpButton()
    private let remoteButtonsControl = NSSegmentedControl()
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
         termsAcceptance: SpeechModelTermsAcceptanceStore = .init(),
         speechModels: SpeechModelLibraryClient = .shared) {
        self.settings = settings
        self.library = library
        self.speechModels = speechModels
        self.termsAcceptance = termsAcceptance
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

    deinit {
        diagnosticsExpiryTask?.cancel()
    }

    /// MAC-SETTINGS-TABS-LIKE-LINUX: sections follow the Linux client — Models,
    /// Reader, Playback, Storage, Advanced, About — with the iPhone rows.
    private func configureControls() {
        statusLabel.textColor = .readableSecondaryLabel
        storageLabel.textColor = .readableSecondaryLabel
        let models = MacSettingsSections.disclosureRow(
            title: L10n.string("models.title"), subtitle: L10n.string("settings.modelsSubtitle"),
            symbol: "person.wave.2", identifier: "settings.speechModels.disclosure",
            target: self, action: #selector(showVoiceModels))
        let readingPreferences = MacSettingsSections.disclosureRow(
            title: L10n.string("settings.readingPreferences"),
            subtitle: L10n.string("settings.readingPreferencesSubtitle"), symbol: "textformat",
            identifier: "settings.readingPreferences.disclosure",
            target: self, action: #selector(showReadingPreferences))
        let preferences: [NSView] = [
            MacSettingsSections.header(L10n.string("settings.reader")),
            MacSettingsSections.card([readingPreferences.row] + readerToggleRows()),
            MacSettingsSections.footer(L10n.string("settings.readerFooter")),
            MacSettingsSections.header(L10n.string("settings.playback")),
            MacSettingsSections.card(playbackRows()),
            MacSettingsSections.footer(L10n.string("settings.playbackFooter")),
            MacSettingsSections.header(L10n.string("settings.storage")),
            MacSettingsSections.card(storageRows()),
            MacSettingsSections.header(L10n.string("settings.advanced")),
            MacSettingsSections.card(advancedRows()),
            MacSettingsSections.header(L10n.string("settings.about")),
            MacSettingsSections.card(aboutRows()),
        ]
        let columns = MacSettingsColumns(narration: [MacSettingsSections.card([models.row])],
                                         preferences: preferences)
        columns.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(columns)
        NSLayoutConstraint.activate([
            columns.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            columns.topAnchor.constraint(equalTo: view.topAnchor),
            columns.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func readerToggleRows() -> [NSView] {
        let autoScroll = MacSettingsSections.switchControl(
            isOn: settings.readerAutoScroll, label: L10n.string("settings.autoScroll"),
            identifier: "settings.reader.autoScroll", target: self, action: #selector(autoScrollChanged(_:)))
        let tracking = MacSettingsSections.switchControl(
            isOn: settings.readerAudioTrackingEnabled, label: L10n.string("readerSettings.audioTracking"),
            identifier: "settings.reader.audioTracking", target: self, action: #selector(audioTrackingChanged(_:)))
        return [
            MacSettingsSections.row(title: L10n.string("settings.autoScroll"), symbol: "arrow.down.to.line",
                                    accessory: autoScroll),
            MacSettingsSections.row(title: L10n.string("readerSettings.audioTracking"),
                                    subtitle: L10n.string("readerSettings.audioTrackingDescription"),
                                    symbol: "text.word.spacing", accessory: tracking),
        ]
    }

    private func playbackRows() -> [NSView] {
        let seconds = Self.skipIntervals.map { L10n.string("settings.seconds", $0) }
        for (popup, key) in [(skipBackwardPopup, "settings.skipBackward"), (skipForwardPopup, "settings.skipForward")] {
            popup.removeAllItems()
            popup.addItems(withTitles: seconds)
            popup.target = self
            popup.action = #selector(skipIntervalChanged(_:))
            popup.setAccessibilityLabel(L10n.string(key))
            popup.setAccessibilityIdentifier(key)
        }
        remoteButtonsControl.segmentCount = RemoteButtonMode.allCases.count
        for (index, mode) in RemoteButtonMode.allCases.enumerated() {
            remoteButtonsControl.setLabel(mode.title, forSegment: index)
        }
        remoteButtonsControl.trackingMode = .selectOne
        remoteButtonsControl.target = self
        remoteButtonsControl.action = #selector(remoteButtonsChanged(_:))
        remoteButtonsControl.setAccessibilityLabel(L10n.string("settings.remoteButtons"))
        remoteButtonsControl.setAccessibilityIdentifier("settings.remoteButtons")
        let remote = NSStackView(views: [
            MacSettingsSections.row(title: L10n.string("settings.remoteButtons"), symbol: "car"),
            remoteButtonsControl,
        ])
        remote.orientation = .vertical
        remote.alignment = .centerX
        remote.spacing = 4
        remote.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        remote.arrangedSubviews[0].widthAnchor.constraint(equalTo: remote.widthAnchor).isActive = true
        return [
            MacSettingsSections.row(title: L10n.string("settings.skipBackward"), symbol: "gobackward",
                                    accessory: skipBackwardPopup),
            MacSettingsSections.row(title: L10n.string("settings.skipForward"), symbol: "goforward",
                                    accessory: skipForwardPopup),
            remote,
        ]
    }

    private func storageRows() -> [NSView] {
        let refreshButton = NSButton(title: L10n.string("settings.refreshStorage"), target: self,
                                     action: #selector(refreshStorage))
        refreshButton.setAccessibilityLabel(L10n.string("settings.refreshStorage"))
        let clearButton = NSButton(title: L10n.string("settings.clearAllDownloads"), target: self,
                                   action: #selector(clearDownloads))
        clearButton.setAccessibilityLabel(L10n.string("settings.clearAllDownloads"))
        return [
            MacSettingsSections.row(title: L10n.string("settings.storageUsage"), symbol: "internaldrive",
                                    accessory: storageLabel),
            MacSettingsSections.row(title: L10n.string("settings.refreshStorage"), symbol: "arrow.clockwise",
                                    accessory: refreshButton),
            MacSettingsSections.row(title: L10n.string("settings.clearAllDownloads"), symbol: "trash",
                                    accessory: clearButton),
        ]
    }

    private func advancedRows() -> [NSView] {
        let exportDiagnosticsButton = NSButton(
            title: L10n.string("settings.exportPerformanceDiagnostics"),
            target: self,
            action: #selector(exportPerformanceDiagnostics)
        )
        exportDiagnosticsButton.setAccessibilityLabel(L10n.string("settings.exportPerformanceDiagnostics"))
        diagnosticsButton.target = self
        diagnosticsButton.action = #selector(toggleStreamingDiagnostics)
        diagnosticsButton.setAccessibilityIdentifier("settings.recordStreamingDiagnostics")
        diagnosticsLabel.setAccessibilityIdentifier("settings.streamingDiagnosticsStatus")
        let diagnostics = NSStackView(views: [exportDiagnosticsButton, diagnosticsButton, diagnosticsLabel])
        diagnostics.orientation = .vertical
        diagnostics.alignment = .leading
        diagnostics.spacing = 8
        diagnostics.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        diagnosticsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diagnosticsLabel.widthAnchor.constraint(lessThanOrEqualTo: diagnostics.widthAnchor,
                                                constant: -32).isActive = true
        return [diagnostics]
    }

    private func aboutRows() -> [NSView] {
        let platform = NSTextField(labelWithString: "macOS")
        platform.textColor = .readableSecondaryLabel
        platform.setAccessibilityIdentifier("settings.platform")
        return [
            MacSettingsSections.row(title: L10n.string("settings.platform"), symbol: "info.circle",
                                    accessory: platform),
            MacSettingsSections.row(title: L10n.string("settings.embeddedServer"), symbol: "cpu",
                                    accessory: statusLabel),
        ]
    }

    private static let skipIntervals = [15, 30, 45, 60]

    @objc private func showReadingPreferences() {
        guard voiceModelDestination == nil, children.isEmpty else { return }
        pushDetail(MacReadingPreferencesViewController(settings: settings)) { [weak self] in self?.refresh() }
    }

    @objc private func autoScrollChanged(_ sender: NSSwitch) {
        settings.readerAutoScroll = sender.state == .on
    }

    @objc private func audioTrackingChanged(_ sender: NSSwitch) {
        settings.readerAudioTrackingEnabled = sender.state == .on
    }

    @objc private func skipIntervalChanged(_ sender: NSPopUpButton) {
        guard Self.skipIntervals.indices.contains(sender.indexOfSelectedItem) else { return }
        let value = Double(Self.skipIntervals[sender.indexOfSelectedItem])
        if sender === skipForwardPopup {
            settings.playbackForwardSeconds = value
        } else {
            settings.playbackBackwardSeconds = value
        }
        PlaybackSystemSession.refreshSkipIntervals()
    }

    @objc private func remoteButtonsChanged(_ sender: NSSegmentedControl) {
        guard RemoteButtonMode.allCases.indices.contains(sender.selectedSegment) else { return }
        settings.remoteButtonMode = RemoteButtonMode.allCases[sender.selectedSegment]
    }

    @objc private func showVoiceModels() {
        guard voiceModelDestination == nil else { return }
        let previousViews = view.subviews.map { ($0, $0.isHidden) }
        // The single Models entry: models by language, one choice per language, with
        // install, remove, preview and licence actions inside the screen.
        let detail = MacModelsViewController(settings: settings, source: SpeechModelsSource(client: speechModels),
                                             termsAcceptance: termsAcceptance)
        let destination = MacSettingsDetailNavigation(detail: detail) { [weak self] in
            guard let self, let destination = self.voiceModelDestination else { return }
            destination.view.removeFromSuperview()
            destination.removeFromParent()
            self.voiceModelDestination = nil
            previousViews.forEach { $0.0.isHidden = $0.1 }
            self.refresh()
        }
        voiceModelDestination = destination
        previousViews.forEach { $0.0.isHidden = true }
        addChild(destination)
        destination.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(destination.view)
        NSLayoutConstraint.activate([
            destination.view.topAnchor.constraint(equalTo: view.topAnchor),
            destination.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            destination.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            destination.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func refresh() {
        select(Self.skipIntervals.firstIndex(of: Int(settings.playbackBackwardSeconds)), in: skipBackwardPopup)
        select(Self.skipIntervals.firstIndex(of: Int(settings.playbackForwardSeconds)), in: skipForwardPopup)
        remoteButtonsControl.selectedSegment = RemoteButtonMode.allCases.firstIndex(of: settings.remoteButtonMode) ?? 0
        statusLabel.stringValue = embeddedRuntimeStatusLabel
        storageLabel.stringValue = formatStorage(StorageUsageScanner.current())
    }

    private var embeddedRuntimeStatusLabel: String {
        L10n.string("settings.embeddedRuntime.ready")
    }

    private func formatStorage(_ usage: StorageUsageSnapshot) -> String {
        ByteCountFormatter.string(fromByteCount: usage.totalBytes, countStyle: .file)
    }

    private func select(_ index: Int?, in popup: NSPopUpButton) {
        guard let index, index < popup.numberOfItems else { return }
        popup.selectItem(at: index)
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
