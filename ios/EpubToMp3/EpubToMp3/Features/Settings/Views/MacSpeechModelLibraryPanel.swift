#if os(macOS)
import AppKit

private final class MacSpeechModelActionButton: NSButton {
    let modelID: String
    let modelAction: SpeechModelProductAction

    init(modelID: String, modelAction: SpeechModelProductAction, title: String) {
        self.modelID = modelID
        self.modelAction = modelAction
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class MacSpeechModelLibraryPanel: NSStackView {
    var onSnapshot: ((SpeechModelLibraryViewState) -> Void)?

    private let settings: AppSettings
    private let audition = VoiceAuditionPresentation()
    private let speechModels: SpeechModelLibraryClient
    private let termsAcceptance: SpeechModelTermsAcceptanceStore
    private var state: SpeechModelLibraryViewState
    private var disclosure = SpeechModelSettingsDisclosure()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var disclosureButton = NSButton(title: "", target: self, action: #selector(toggleModels))
    private var installEvents: [String: SpeechModelInstallEvent] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]
    private var reloadTask: Task<Void, Never>?
    private struct RenderedRow {
        let label: NSTextField
        let actions: [SpeechModelProductAction]
    }
    private var renderedRows: [String: RenderedRow] = [:]

    init(
        settings: AppSettings,
        speechModels: SpeechModelLibraryClient,
        termsAcceptance: SpeechModelTermsAcceptanceStore
    ) {
        self.settings = settings
        self.speechModels = speechModels
        self.termsAcceptance = termsAcceptance
        self.state = SpeechModelLibraryViewState(snapshot: speechModels.initialSnapshot)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        setAccessibilityIdentifier("settings.speechModels")
        disclosureButton.setAccessibilityIdentifier("settings.speechModels.disclosure")
        summaryLabel.setAccessibilityIdentifier("settings.speechModels.summary")
        addArrangedSubview(disclosureButton)
        addArrangedSubview(summaryLabel)
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        reloadTask?.cancel()
        installTasks.values.forEach { $0.cancel() }
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await speechModels.snapshot()
                guard !Task.isCancelled else { return }
                adopt(snapshot)
                observeInstalls(in: snapshot.entries)
            } catch {
                // Keep the last valid snapshot and persisted selections.
            }
        }
    }

    func render() {
        renderedRows.removeAll()
        refreshSummary()
        arrangedSubviews.filter { $0 !== disclosureButton && $0 !== summaryLabel }.forEach { view in
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard disclosure.isExpanded else { return }
        guard !state.entries.isEmpty else {
            addArrangedSubview(NSTextField(labelWithString: L10n.string("settings.modelState.notInspected")))
            return
        }
        let language = NSPopUpButton()
        for tag in state.studyLanguages {
            language.addItem(withTitle: state.languageTitle(tag))
            language.lastItem?.representedObject = tag
            if tag == state.studyLanguage { language.selectItem(at: language.numberOfItems - 1) }
        }
        language.target = self
        language.action = #selector(studyLanguageChanged(_:))
        language.setAccessibilityIdentifier("settings.speechModels.language")
        language.setAccessibilityLabel(L10n.string("settings.modelLanguage.study"))
        addArrangedSubview(NSStackView(views: [
            NSTextField(labelWithString: L10n.string("settings.modelLanguage.study")), language,
        ]))
        for entry in state.orderedEntries {
            addArrangedSubview(makeRow(for: entry))
        }
    }

    @objc private func toggleModels() {
        disclosure.toggle()
        render()
    }

    private func refreshSummary() {
        disclosureButton.title = L10n.string(disclosure.isExpanded ? "settings.models.hide" : "settings.models.show")
        disclosureButton.setAccessibilityValue(L10n.string(disclosure.isExpanded ? "settings.models.expanded" : "settings.models.collapsed"))
        summaryLabel.stringValue = SpeechModelSettingsDisclosure.summary(state: state,
            primary: settings.ttsPreferences.primary, events: installEvents)
    }

    @objc private func studyLanguageChanged(_ sender: NSPopUpButton) {
        guard let language = sender.selectedItem?.representedObject as? String else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                adopt(try await speechModels.setStudyLanguage(language))
            } catch {
                presentFailure(title: L10n.string("settings.modelLanguage.study"), error: error)
                render()
            }
        }
    }

    private func detailText(for entry: SpeechModelSnapshot.Entry) -> String {
        var labelLines = [state.displayName(for: entry)]
        if let event = installEvents[entry.identity.modelID] {
            labelLines.append(state.installStatus(for: event))
        }
        labelLines.append(state.details(
            for: entry,
            configuredSelections: settings.configuredNarrationSelections
        ))
        return labelLines.joined(separator: "\n")
    }

    private func actions(for entry: SpeechModelSnapshot.Entry) -> SpeechModelProductActions {
        state.actions(
            for: entry,
            configuredSelections: settings.configuredNarrationSelections,
            installEvent: installEvents[entry.identity.modelID],
            termsAccepted: termsAcceptance.isAccepted(
                modelID: entry.identity.modelID,
                fingerprint: entry.licence.termsFingerprint
            )
        )
    }

    private func updateInstallRow(modelID: String) {
        refreshSummary()
        guard disclosure.isExpanded else { return }
        guard let entry = state.entries.first(where: { $0.identity.modelID == modelID }),
              let row = renderedRows[modelID], row.actions == actions(for: entry).available else {
            render()
            return
        }
        // Progress must not replace a button while a user is pressing it.
        row.label.stringValue = detailText(for: entry)
    }

    private func makeRow(for entry: SpeechModelSnapshot.Entry) -> NSView {
        let label = NSTextField(wrappingLabelWithString: detailText(for: entry))
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityIdentifier("settings.speechModel.\(entry.identity.modelID).details")
        let modelID = entry.identity.modelID
        let actions = actions(for: entry)
        renderedRows[modelID] = RenderedRow(label: label, actions: actions.available)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for action in actions.available {
            let button = MacSpeechModelActionButton(
                modelID: modelID, modelAction: action, title: state.actionTitle(for: action)
            )
            button.target = self
            button.action = #selector(actionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(action.rawIdentifier)
            button.setAccessibilityIdentifier("settings.speechModel.\(modelID).\(action.rawIdentifier)")
            buttons.addArrangedSubview(button)
        }
        let row = NSStackView(views: [label, buttons])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 5
        return row
    }

    @objc private func actionClicked(_ sender: MacSpeechModelActionButton) {
        let modelID = sender.modelID
        let action = sender.modelAction
        guard
              let entry = state.entries.first(where: { $0.identity.modelID == modelID }) else { return }
        perform(action, for: entry)
    }

    private func perform(_ action: SpeechModelProductAction, for entry: SpeechModelSnapshot.Entry) {
        switch action {
        case .preview:
            guard let selection = state.selection(for: entry) else { return }
            audition.present(selection: selection, language: entry.languageEvidence.exactTags.first?.tag ?? state.studyLanguage, on: window)
        case .install: confirmInstall(entry)
        case .cancelInstall:
            Task { await speechModels.cancelInstall(modelID: entry.identity.modelID) }
        case .select:
            guard let selection = state.selection(for: entry) else { return }
            settings.selectPrimaryNarration(selection)
            render()
            onSnapshot?(state)
        case .remove: confirmRemoval(entry)
        case .revokeTerms:
            guard let fingerprint = entry.licence.termsFingerprint else { return }
            termsAcceptance.revoke(modelID: entry.identity.modelID, fingerprint: fingerprint)
            render()
        }
    }

    private func confirmInstall(_ entry: SpeechModelSnapshot.Entry) {
        let needsTerms = entry.licence.requiresAcceptance
            && !termsAcceptance.isAccepted(
                modelID: entry.identity.modelID,
                fingerprint: entry.licence.termsFingerprint
            )
        if needsTerms {
            confirmTermsAcceptance(entry)
            return
        }
        let alert = NSAlert()
        alert.messageText = state.installTitle(for: entry)
        alert.informativeText = state.details(
            for: entry,
            configuredSelections: settings.configuredNarrationSelections
        )
        alert.addButton(withTitle: L10n.string("settings.modelInstall.confirm"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        present(alert) { [weak self] accepted in
            guard accepted, let self else { return }
            install(
                entry,
                acceptedTermsFingerprint: entry.licence.requiresAcceptance
                    ? entry.licence.termsFingerprint : nil
            )
        }
    }

    private func confirmTermsAcceptance(_ entry: SpeechModelSnapshot.Entry) {
        guard let fingerprint = entry.licence.termsFingerprint else {
            presentFailure(
                title: state.installTitle(for: entry),
                error: SpeechModelInstallationError.termsAcceptanceRequired(entry.identity.modelID)
            )
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.string("settings.modelTerms.acceptTitle")
        alert.informativeText = termsAcceptanceMessage(for: entry)
        alert.addButton(withTitle: L10n.string("settings.modelTerms.accept"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        present(alert) { [weak self] accepted in
            guard accepted, let self else { return }
            termsAcceptance.accept(modelID: entry.identity.modelID, fingerprint: fingerprint)
            confirmInstall(entry)
        }
    }

    private func termsAcceptanceMessage(for entry: SpeechModelSnapshot.Entry) -> String {
        var fields = [state.details(
            for: entry,
            configuredSelections: settings.configuredNarrationSelections
        )]
        if let evidenceURL = entry.licence.evidenceURL {
            fields.append(evidenceURL.absoluteString)
        }
        return fields.joined(separator: "\n")
    }

    private func install(
        _ entry: SpeechModelSnapshot.Entry,
        acceptedTermsFingerprint: String?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await speechModels.install(
                    modelID: entry.identity.modelID,
                    acceptedTermsFingerprint: acceptedTermsFingerprint
                )
                adopt(try await speechModels.snapshot())
            } catch is CancellationError {
                // The operation event already renders cancellation.
            } catch {
                presentFailure(title: state.installTitle(for: entry), error: error)
            }
        }
    }

    private func confirmRemoval(_ entry: SpeechModelSnapshot.Entry) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("settings.modelRemove.confirmTitle", state.displayName(for: entry))
        alert.informativeText = L10n.string("settings.modelRemove.confirmMessage")
        alert.addButton(withTitle: L10n.string("common.remove"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        present(alert) { [weak self] accepted in
            guard accepted else { return }
            self?.remove(entry)
        }
    }

    private func remove(_ entry: SpeechModelSnapshot.Entry) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await speechModels.remove(
                    modelID: entry.identity.modelID,
                    configuredSelections: settings.configuredNarrationSelections
                )
                installEvents.removeValue(forKey: entry.identity.modelID)
                adopt(snapshot)
            } catch {
                presentFailure(title: L10n.string("settings.modelRemove.failed"), error: error)
            }
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping (Bool) -> Void) {
        if let window {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func presentFailure(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = AppErrorReporter.message(error, context: #function)
        alert.addButton(withTitle: L10n.string("common.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func adopt(_ snapshot: SpeechModelSnapshot) {
        state = SpeechModelLibraryViewState(snapshot: snapshot)
        render()
        onSnapshot?(state)
    }

    private func observeInstalls(in entries: [SpeechModelSnapshot.Entry]) {
        installTasks.values.forEach { $0.cancel() }
        installTasks.removeAll()
        for entry in entries where entry.distribution.installable {
            let modelID = entry.identity.modelID
            installTasks[modelID] = Task { [weak self] in
                guard let self else { return }
                let events = await speechModels.watchInstall(modelID: modelID)
                for await event in events {
                    guard !Task.isCancelled else { return }
                    installEvents[modelID] = event
                    if event.stage == .completed,
                       let snapshot = try? await speechModels.snapshot() {
                        installEvents.removeValue(forKey: modelID)
                        adopt(snapshot)
                    } else {
                        updateInstallRow(modelID: modelID)
                    }
                }
            }
        }
    }

}

private extension SpeechModelProductAction {
    var rawIdentifier: String {
        switch self {
        case .preview: return "preview"
        case .install: return "install"
        case .cancelInstall: return "cancel"
        case .select: return "select"
        case .remove: return "remove"
        case .revokeTerms: return "revokeTerms"
        }
    }
}
#endif
