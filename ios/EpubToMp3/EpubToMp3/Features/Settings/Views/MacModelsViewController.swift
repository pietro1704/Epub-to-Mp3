#if os(macOS)
import AppKit
import Combine

/// The macOS Models screen: every catalog model grouped by language, split into
/// local and online, one choice per language. Clicking a ready row chooses it,
/// clicking a dimmed downloadable row starts its download at once, and the
/// row's menu carries preview, removal, cancel and the licence actions.
@MainActor
final class MacModelsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private enum Item {
        case header(String, footer: String?)
        /// A root row: the voice for one language.
        case language(ModelsByLanguageModel.RootItem)
        /// The language page's first row: no voice chosen for the language.
        case automatic(language: String, isChosen: Bool)
        case model(ModelsByLanguageViewState.Row, language: String)
    }

    private let model: ModelsByLanguageModel
    var audition = VoiceAuditionPresentation()
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let automaticFallbackButton = NSSwitch()
    private let onlineFallbackButton = NSSwitch()
    private let footnotesButton = NSSwitch()
    private let silenceTrimPopup = NSPopUpButton()
    private let lowQualityButton = NSSwitch()
    private let bookLanguages: () -> [String]
    private var items: [Item] = []
    private var observations: Set<AnyCancellable> = []
    private var shownFailures: Set<String> = []
    private let focusLanguage: String?
    /// Set on the screen pushed from the language list: it shows that language's models only.
    private let onlyLanguage: String?
    private let languagesButton = NSButton(title: "", target: nil, action: nil)
    /// While a screen is pushed over this one, only the topmost screen presents sheets.
    private var coveredByPush = false

    init(settings: AppSettings, source: ModelsByLanguageSource = SpeechModelsSource(),
         termsAcceptance: SpeechModelTermsAcceptanceStore = .init(), focusLanguage: String? = nil,
         bookLanguages: @escaping () -> [String] = { BookLanguageSummaries().languages(corrections: .init()) }) {
        self.bookLanguages = bookLanguages
        self.model = ModelsByLanguageModel(source: source, settings: settings, terms: termsAcceptance)
        self.model.priorityLanguage = focusLanguage
        self.focusLanguage = focusLanguage
        self.onlyLanguage = nil
        super.init(nibName: nil, bundle: nil)
        title = L10n.string("models.title")
    }

    /// The language page: an Automatic row, then the voices by engine. It shares the model (and its loaded
    /// catalog) of the screen it is pushed from.
    init(sharing model: ModelsByLanguageModel, onlyLanguage: String) {
        self.model = model
        self.bookLanguages = { [] }
        self.focusLanguage = nil
        self.onlyLanguage = onlyLanguage
        super.init(nibName: nil, bundle: nil)
        title = (Locale.current.localizedString(forLanguageCode: onlyLanguage) ?? onlyLanguage).capitalized
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        // A zero-sized root would shrink a hosting window and wrap the option descriptions letter by letter.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 760))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.usesAutomaticRowHeights = true
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.setAccessibilityIdentifier("models.table")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        statusLabel.textColor = .readableSecondaryLabel
        statusLabel.stringValue = L10n.string("models.loading")
        // The root mirrors the iPhone 16e: each narration option is a switch row with its description,
        // then a "Languages" row with a globe and a disclosure chevron (MAC-MODELS-BY-LANGUAGE).
        let options: [(NSSwitch, String, String, String, Selector)] = [
            (automaticFallbackButton, "settings.automaticSystemFallback", "settings.automaticSystemFallbackDescription",
             "settings.tts.automaticSystemFallback", #selector(automaticFallbackChanged)),
            (onlineFallbackButton, "settings.onlineFallback", "settings.onlineFallbackDescription",
             "settings.tts.onlineConsent", #selector(onlineFallbackChanged)),
            (footnotesButton, "settings.footnoteNarration", "settings.footnoteNarrationDescription",
             "settings.tts.footnoteNarration", #selector(footnotesChanged)),
            (lowQualityButton, "models.showLowQuality", "models.showLowQualityDescription",
             "models.showLowQuality", #selector(lowQualityChanged)),
        ]
        var rows: [NSView] = options.map { toggle, titleKey, descriptionKey, identifier, action in
            toggle.target = self
            toggle.action = action
            toggle.setAccessibilityIdentifier(identifier)
            toggle.setAccessibilityLabel(L10n.string(titleKey))
            toggle.setAccessibilityHelp(L10n.string(descriptionKey))
            return MacSettingsSections.row(title: L10n.string(titleKey), subtitle: L10n.string(descriptionKey),
                                           accessory: toggle)
        }
        silenceTrimPopup.addItems(withTitles: SilenceTrim.allCases.map(\.title))
        silenceTrimPopup.target = self
        silenceTrimPopup.action = #selector(silenceTrimChanged)
        silenceTrimPopup.setAccessibilityIdentifier("settings.tts.silenceTrim")
        silenceTrimPopup.setAccessibilityLabel(L10n.string("silenceTrim.title"))
        silenceTrimPopup.setAccessibilityHelp(L10n.string("silenceTrim.description"))
        // Same place as on the iPhone: right after the footnote switch.
        rows.insert(MacSettingsSections.row(title: L10n.string("silenceTrim.title"),
                                            subtitle: L10n.string("silenceTrim.description"),
                                            accessory: silenceTrimPopup), at: 3)
        languagesButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        languagesButton.imagePosition = .imageOnly
        languagesButton.isBordered = false
        languagesButton.target = self
        languagesButton.action = #selector(showLanguages)
        languagesButton.setAccessibilityIdentifier("models.languages")
        languagesButton.setAccessibilityLabel(L10n.string("models.languages"))
        let languagesRow = MacSettingsSections.row(title: L10n.string("models.languages.open"), symbol: "globe",
                                                   accessory: languagesButton)
        languagesRow.addGestureRecognizer(NSClickGestureRecognizer(target: languagesButton,
                                                                   action: #selector(NSButton.performClick(_:))))
        rows.append(languagesRow)
        let narrationBox = NSStackView(views: [MacSettingsSections.card(rows)])
        narrationBox.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 8, right: 16)
        narrationBox.arrangedSubviews[0].widthAnchor
            .constraint(equalTo: narrationBox.widthAnchor, constant: -32).isActive = true
        narrationBox.isHidden = onlyLanguage != nil
        let stack = NSStackView(views: [narrationBox, statusLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            narrationBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &observations)
        guard onlyLanguage == nil else { refresh(); return }
        Task { [weak self] in
            await self?.model.load()
            self?.refresh()
        }
    }

    private func refresh() {
        statusLabel.stringValue = model.isLoading ? L10n.string("models.loading")
            : (model.loadFailure != nil ? L10n.string("models.loadFailed") : "")
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        languagesButton.isEnabled = !model.catalogLanguages.isEmpty
        if let onlyLanguage {
            items = model.state.section(for: onlyLanguage).map(languagePageItems) ?? []
        } else {
            items = [.header(L10n.string("models.root.header"), footer: nil)]
                + model.rootItems(bookLanguages: bookLanguages(), priority: focusLanguage).map(Item.language)
        }
        refreshNarration()
        table.reloadData()
        presentPendingTermsIfNeeded()
        presentNewFailures()
    }

    private func languagePageItems(_ section: ModelsByLanguageViewState.Section) -> [Item] {
        [.automatic(language: section.language, isChosen: section.chosen == nil)]
            + section.engineSections.flatMap { engine in
                [Item.header(engine.engine.title, footer: nil)] + engine.rows.map { .model($0, language: section.language) }
            }
    }

    // MARK: narration

    private func refreshNarration() {
        automaticFallbackButton.state = model.allowAutomaticSystemVoiceFallback ? .on : .off
        onlineFallbackButton.state = model.allowOnlineFallback ? .on : .off
        footnotesButton.state = model.narratesFootnotes ? .on : .off
        silenceTrimPopup.selectItem(at: SilenceTrim.allCases.firstIndex(of: model.silenceTrim) ?? 0)
        lowQualityButton.state = model.showLowQuality ? .on : .off
    }

    @objc private func automaticFallbackChanged() { model.allowAutomaticSystemVoiceFallback = automaticFallbackButton.state == .on }
    @objc private func footnotesChanged() { model.narratesFootnotes = footnotesButton.state == .on }
    @objc private func silenceTrimChanged() {
        model.silenceTrim = SilenceTrim.allCases[silenceTrimPopup.indexOfSelectedItem]
    }
    @objc private func onlineFallbackChanged() { model.allowOnlineFallback = onlineFallbackButton.state == .on }
    @objc private func lowQualityChanged() {
        let show = lowQualityButton.state == .on
        Task { [weak self] in await self?.model.setShowLowQuality(show) }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = items[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case let .header(text, footer):
            let title = NSTextField(labelWithString: text)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            var views: [NSView] = [title]
            if let footer {
                let note = NSTextField(wrappingLabelWithString: footer)
                note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                note.textColor = .readableSecondaryLabel
                views.append(note)
            }
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 4, right: 12)
            return stack
        case let .language(item):
            return languageView(item)
        case let .automatic(language, isChosen):
            return automaticView(language: language, isChosen: isChosen)
        case let .model(row, language):
            return rowView(row, language: language)
        }
    }

    private func languageView(_ item: ModelsByLanguageModel.RootItem) -> NSView {
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        let detail = NSTextField(wrappingLabelWithString: item.detail)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .readableSecondaryLabel
        let texts = NSStackView(views: [title, detail])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        var views: [NSView] = []
        if item.needsVoice, let warning = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil) {
            views.append(NSImageView(image: warning))
        }
        views += [texts, NSView()]
        if let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
            views.append(NSImageView(image: chevron))
        }
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.button)
        stack.setAccessibilityIdentifier("models.language.\(item.language)")
        stack.setAccessibilityLabel("\(item.title), \(item.detail)")
        return stack
    }

    private func automaticView(language: String, isChosen: Bool) -> NSView {
        let title = NSTextField(labelWithString: (isChosen ? "✓ " : "") + L10n.string("models.page.automatic"))
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        let note = NSTextField(wrappingLabelWithString: L10n.string("models.automatic"))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .readableSecondaryLabel
        let stack = NSStackView(views: [title, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.setAccessibilityIdentifier("models.automatic.\(language)")
        stack.setAccessibilityValue(isChosen ? L10n.string("models.inUse") : nil)
        return stack
    }

    private func rowView(_ row: ModelsByLanguageViewState.Row, language: String) -> NSView {
        let title = NSTextField(labelWithString: (row.isChosen ? "✓ " : "") + row.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Dimmed rows (not downloaded / unavailable) read as secondary, never faded below legibility.
        title.textColor = row.isDimmed ? .readableSecondaryLabel : .labelColor
        let subtitle = NSTextField(wrappingLabelWithString: subtitle(for: row))
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .readableSecondaryLabel
        let texts = NSStackView(views: [title, subtitle])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        var views: [NSView] = [texts]
        if let value = model.progress[row.id] {
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = value
            bar.widthAnchor.constraint(equalToConstant: 90).isActive = true
            views.append(bar)
        }
        let menu = NSButton(image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: #selector(showMenu(_:)))
        menu.isBordered = false
        menu.identifier = NSUserInterfaceItemIdentifier("\(language)|\(row.id)")
        menu.setAccessibilityIdentifier("models.menu.\(language).\(row.id)")
        menu.isHidden = actions(for: row, in: language).isEmpty
        views.append(menu)
        let stack = NSStackView(views: views)
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        stack.setAccessibilityIdentifier("models.row.\(language).\(row.id)")
        stack.setAccessibilityValue(row.isChosen ? L10n.string("models.inUse") : nil)
        return stack
    }

    private func subtitle(for row: ModelsByLanguageViewState.Row) -> String {
        var parts: [String] = []
        if !row.detail.isEmpty, row.detail != "unspecified" { parts.append(L10n.string("settings.modelQuality.\(row.detail)")) }
        if let value = model.progress[row.id] {
            parts.append(L10n.string("models.downloading", Int((value * 100).rounded())))
        } else if let failure = model.failures[row.id] {
            parts.append(failure)
        } else {
            switch row.availability {
            case .ready: if row.isChosen { parts.append(L10n.string("models.inUse")) }
            case let .downloadable(bytes):
                parts.append(L10n.string("models.download",
                    bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""))
            case .needsConsent: parts.append(L10n.string("models.needsConsent"))
            case .unavailable: parts.append(L10n.string("models.unavailable"))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: actions

    @objc private func rowClicked() { activateRow(at: table.clickedRow) }

    /// What a click on a row does (also driven directly by tests).
    func activateRow(at index: Int) {
        guard items.indices.contains(index) else { return }
        if case let .automatic(language, _) = items[index] { return model.clearChoice(in: language) }
        if case let .language(item) = items[index] {
            return push(MacModelsViewController(sharing: model, onlyLanguage: item.language))
        }
        guard case let .model(row, language) = items[index] else { return }
        switch row.availability {
        case .ready:
            if row.isChosen { model.clearChoice(in: language) }
            else if row.isExplicitOnly { Task { [weak self] in await self?.model.chooseExplicit(row, in: language) } }
            else { model.choose(row, in: language) }
        case .downloadable:
            Task { [weak self] in await self?.model.download(row, in: language) }
        case .needsConsent:
            explainOnlineConsent()
        case .unavailable: break
        }
    }

    private struct MenuAction { let title: String; let destructive: Bool; let run: () -> Void }

    private func actions(for row: ModelsByLanguageViewState.Row, in language: String) -> [MenuAction] {
        var result: [MenuAction] = []
        let library = model.libraryState(for: language)
        if model.progress[row.id] != nil {
            result.append(MenuAction(title: L10n.string("settings.modelInstall.cancel"), destructive: true) { [weak self] in
                Task { await self?.model.cancelDownload(row) }
            })
        }
        // An online voice offers its sample even before the consent: choosing it explains why it cannot play.
        if row.availability == .ready || (row.selection.isEdge && row.availability == .needsConsent) {
            result.append(MenuAction(title: library.actionTitle(for: .preview), destructive: false) { [weak self] in
                self?.preview(row, in: language)
            })
        }
        if row.availability == .ready {
            if row.isChosen {
                result.append(MenuAction(title: L10n.string("models.action.useAutomatic"), destructive: false) { [weak self] in
                    self?.model.clearChoice(in: language)
                })
            }
            if row.selection.engine == "piper" {
                result.append(MenuAction(title: library.actionTitle(for: .remove), destructive: true) { [weak self] in
                    self?.confirmRemoval(row, in: language)
                })
            }
        }
        if let entry = model.entry(forRow: row, in: language), entry.licence.requiresAcceptance, model.isTermsAccepted(for: entry) {
            result.append(MenuAction(title: library.actionTitle(for: .revokeTerms), destructive: true) { [weak self] in
                self?.model.revokeTerms(for: entry)
            })
        }
        return result
    }

    /// Runs one entry of a row's menu by its title (also driven directly by tests).
    @discardableResult
    func runRowAction(titled title: String, rowID: String, language: String) -> Bool {
        guard let row = model.state.sections.first(where: { $0.language == language })?.rows.first(where: { $0.id == rowID }),
              let action = actions(for: row, in: language).first(where: { $0.title == title }) else { return false }
        action.run()
        return true
    }

    private var menuActions: [MenuAction] = []

    @objc private func showMenu(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let split = id.firstIndex(of: "|") else { return }
        let language = String(id[..<split]), rowID = String(id[id.index(after: split)...])
        guard let row = model.state.sections.first(where: { $0.language == language })?.rows.first(where: { $0.id == rowID })
        else { return }
        menuActions = actions(for: row, in: language)
        let menu = NSMenu()
        for (index, action) in menuActions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func runMenuAction(_ item: NSMenuItem) {
        guard menuActions.indices.contains(item.tag) else { return }
        menuActions[item.tag].run()
    }

    private func explainOnlineConsent() {
        showInfo(title: L10n.string("models.consent.title"), message: L10n.string("models.consent.message"))
    }

    private func preview(_ row: ModelsByLanguageViewState.Row, in language: String) {
        // Read at play time: Edge samples go online only while the consent is on.
        if row.selection.isEdge, !model.allowOnlineFallback { return explainOnlineConsent() }
        Task { [weak self] in
            guard let self else { return }
            do {
                let choice = try await model.auditionChoice(for: row, in: language)
                audition.present(selection: choice.selection, language: choice.language,
                                 allowOnlineFallback: model.allowOnlineFallback, on: view.window)
            } catch {
                showInfo(title: L10n.string("voiceAudition.title"), message: AppErrorReporter.message(error, context: #function))
            }
        }
    }

    private func confirmRemoval(_ row: ModelsByLanguageViewState.Row, in language: String) {
        guard let entry = model.entry(forRow: row, in: language) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("settings.modelRemove.confirmTitle", model.libraryState(for: language).displayName(for: entry))
        alert.informativeText = L10n.string("settings.modelRemove.confirmMessage")
        alert.addButton(withTitle: L10n.string("common.remove"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        present(alert) { [weak self] accepted in
            guard accepted else { return }
            Task { [weak self] in
                guard let self else { return }
                do { try await model.remove(row, in: language) } catch {
                    showInfo(title: L10n.string("settings.modelRemove.failed"), message: AppErrorReporter.message(error, context: #function))
                }
            }
        }
    }

    @objc private func showLanguages() {
        let list = MacModelsLanguagesViewController(languages: model.catalogLanguages)
        list.onSelect = { [weak list, model] tag in
            list?.pushDetail(MacModelsViewController(sharing: model, onlyLanguage: tag))
        }
        push(list)
    }

    private func push(_ detail: NSViewController) {
        coveredByPush = true
        pushDetail(detail, onPop: { [weak self] in
            self?.coveredByPush = false
            self?.refresh()
        })
    }

    private func presentPendingTermsIfNeeded() {
        guard model.pendingTerms != nil, !coveredByPush, view.window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("settings.modelTerms.acceptTitle")
        alert.informativeText = L10n.string("settings.modelInstall.termsRequired")
        alert.addButton(withTitle: L10n.string("settings.modelTerms.accept"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        present(alert) { [weak self] accepted in
            if accepted { Task { await self?.model.acceptPendingTerms() } } else { self?.model.declinePendingTerms() }
        }
    }

    private func presentNewFailures() {
        guard !coveredByPush, let (id, message) = model.failures.first(where: { !shownFailures.contains($0.key) }) else { return }
        shownFailures.insert(id)
        showInfo(title: L10n.string("settings.modelInstall.failed"), message: message)
    }

    private func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.string("common.ok"))
        present(alert) { _ in }
    }

    private func present(_ alert: NSAlert, completion: @escaping (Bool) -> Void) {
        if let window = view.window {
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
#endif
