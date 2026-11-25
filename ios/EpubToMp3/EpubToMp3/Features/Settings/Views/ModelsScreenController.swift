#if os(iOS)
import UIKit
import Combine

/// The dedicated Models screen: every catalog model grouped by language, split
/// into local and online, one choice per language. A tap on a ready row chooses
/// it, a tap on a dimmed downloadable row starts its download at once, and the
/// info button carries preview, removal, cancel and the licence actions.
@MainActor
final class ModelsScreenController: UITableViewController {
    private struct Group {
        let language: String
        let title: String
        let rows: [ModelsByLanguageViewState.Row]
    }

    private let model: ModelsByLanguageModel
    private let settings: AppSettings
    private let audition = VoiceAuditionPresentation()
    private let focusLanguage: String?
    /// Set on the screen pushed from the language list: it shows that language's models only.
    private let onlyLanguage: String?
    private let bookLanguages: () -> [String]
    /// The voice models of the language page.
    private var groups: [Group] = []
    /// The root: the voice for each language.
    private var languageItems: [ModelsByLanguageModel.RootItem] = []
    private var observations: Set<AnyCancellable> = []
    private var shownFailures: Set<String> = []

    init(settings: AppSettings, source: ModelsByLanguageSource = SpeechModelsSource(),
         termsAcceptance: SpeechModelTermsAcceptanceStore = .init(), focusLanguage: String? = nil,
         bookLanguages: @escaping () -> [String] = { BookLanguageSummaries().languages(corrections: .init()) }) {
        self.bookLanguages = bookLanguages
        self.settings = settings
        self.focusLanguage = focusLanguage
        self.onlyLanguage = nil
        self.model = ModelsByLanguageModel(source: source, settings: settings, terms: termsAcceptance)
        self.model.priorityLanguage = focusLanguage
        super.init(style: .insetGrouped)
        title = L10n.string("models.title")
    }

    /// The language page: an Automatic row, then the voices by engine. It shares the model (and its loaded
    /// catalog) of the screen it is pushed from.
    init(sharing model: ModelsByLanguageModel, settings: AppSettings, onlyLanguage: String) {
        self.bookLanguages = { [] }
        self.settings = settings
        self.focusLanguage = nil
        self.onlyLanguage = onlyLanguage
        self.model = model
        super.init(style: .insetGrouped)
        title = (Locale.current.localizedString(forLanguageCode: onlyLanguage) ?? onlyLanguage).capitalized
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Model")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Narration")
        tableView.register(IOSSwitchCell.self, forCellReuseIdentifier: "Switch")
        tableView.accessibilityIdentifier = "models.table"
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
        if let onlyLanguage {
            groups = model.state.section(for: onlyLanguage).map { section in
                section.engineSections.map {
                    Group(language: section.language, title: $0.engine.title, rows: $0.rows)
                }
            } ?? []
        } else {
            languageItems = model.rootItems(bookLanguages: bookLanguages(), priority: focusLanguage)
        }
        tableView.reloadData()
        presentPendingTermsIfNeeded()
        presentNewFailures()
    }

    // MARK: data source

    /// Section 0 of the root holds the fallback switches, the quality filter and the
    /// language list entry; one section with the voice for each language follows. On the language page
    /// section 0 holds the Automatic row and the voice groups follow.
    private enum NarrationRow: Int, CaseIterable { case automaticSystemFallback, onlineFallback, footnotes, showLowQuality, languages }

    override func numberOfSections(in tableView: UITableView) -> Int { onlyLanguage == nil ? 2 : groups.count + 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return onlyLanguage == nil ? NarrationRow.allCases.count : 1 }
        return onlyLanguage == nil ? languageItems.count : groups[section - 1].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return nil }
        return onlyLanguage == nil ? L10n.string("models.root.header") : groups[section - 1].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0, onlyLanguage != nil { return L10n.string("models.automatic") }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            if let onlyLanguage { return automaticCell(in: onlyLanguage, at: indexPath) }
            return narrationCell(NarrationRow(rawValue: indexPath.row)!, at: indexPath)
        }
        if onlyLanguage == nil { return languageCell(languageItems[indexPath.row], at: indexPath) }
        let group = groups[indexPath.section - 1]
        let row = group.rows[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Model", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = subtitle(for: row)
        content.secondaryTextProperties.numberOfLines = 0
        content.textProperties.color = row.isDimmed ? .secondaryLabel : .label
        cell.contentConfiguration = content
        cell.contentView.alpha = row.isDimmed ? 0.55 : 1
        cell.accessibilityIdentifier = "models.row.\(group.language).\(row.id)"
        cell.accessibilityValue = row.isChosen ? L10n.string("models.inUse") : nil
        if let value = model.progress[row.id] {
            let bar = UIProgressView(progressViewStyle: .default)
            bar.progress = Float(value)
            bar.frame.size.width = 64
            cell.accessoryView = bar
            cell.accessoryType = .none
        } else {
            cell.accessoryView = nil
            cell.accessoryType = row.isChosen ? .checkmark : (hasActions(row, in: group.language) ? .detailButton : .none)
        }
        cell.selectionStyle = row.availability == .unavailable ? .none : .default
        return cell
    }

    private func languageCell(_ item: ModelsByLanguageModel.RootItem, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Model", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.secondaryText = item.detail
        content.secondaryTextProperties.numberOfLines = 0
        content.image = item.needsVoice ? UIImage(systemName: "exclamationmark.triangle") : nil
        cell.contentConfiguration = content
        cell.contentView.alpha = 1
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = "models.language.\(item.language)"
        cell.accessibilityValue = item.detail
        return cell
    }

    /// Checked while the language has no chosen voice.
    private func automaticCell(in language: String, at indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Model", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = L10n.string("models.page.automatic")
        cell.contentConfiguration = content
        cell.contentView.alpha = 1
        let isAutomatic = model.state.section(for: language)?.chosen == nil
        cell.accessoryView = nil
        cell.accessoryType = isAutomatic ? .checkmark : .none
        cell.selectionStyle = .default
        cell.accessibilityIdentifier = "models.automatic.\(language)"
        cell.accessibilityValue = isAutomatic ? L10n.string("models.inUse") : nil
        return cell
    }

    private func subtitle(for row: ModelsByLanguageViewState.Row) -> String {
        var parts = [qualityTitle(row.detail)].compactMap { $0 }
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

    private func qualityTitle(_ raw: String) -> String? {
        raw.isEmpty || raw == "unspecified" ? nil : L10n.string("settings.modelQuality.\(raw)")
    }

    private func narrationCell(_ row: NarrationRow, at indexPath: IndexPath) -> UITableViewCell {
        switch row {
        case .automaticSystemFallback:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
            cell.configure(title: L10n.string("settings.automaticSystemFallback"),
                           subtitle: L10n.string("settings.automaticSystemFallbackDescription"),
                           isOn: model.allowAutomaticSystemVoiceFallback,
                           accessibilityIdentifier: "settings.tts.automaticSystemFallback")
            cell.onValueChanged = { [weak self] isAllowed in self?.model.allowAutomaticSystemVoiceFallback = isAllowed }
            return cell
        case .onlineFallback:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
            cell.configure(title: L10n.string("settings.onlineFallback"),
                           subtitle: L10n.string("settings.onlineFallbackDescription"),
                           isOn: model.allowOnlineFallback, accessibilityIdentifier: "settings.tts.onlineConsent")
            cell.onValueChanged = { [weak self] isAllowed in self?.model.allowOnlineFallback = isAllowed }
            return cell
        case .footnotes:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
            cell.configure(title: L10n.string("settings.footnoteNarration"),
                           subtitle: L10n.string("settings.footnoteNarrationDescription"),
                           isOn: model.narratesFootnotes, accessibilityIdentifier: "settings.tts.footnoteNarration")
            cell.onValueChanged = { [weak self] reads in self?.model.narratesFootnotes = reads }
            return cell
        case .showLowQuality:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
            cell.configure(title: L10n.string("models.showLowQuality"),
                           subtitle: L10n.string("models.showLowQualityDescription"),
                           isOn: model.showLowQuality, accessibilityIdentifier: "models.showLowQuality")
            cell.onValueChanged = { [weak self] show in Task { await self?.model.setShowLowQuality(show) } }
            return cell
        case .languages:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Narration", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("models.languages.open")
            content.image = UIImage(systemName: "globe")
            cell.contentConfiguration = content
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "models.languages"
            cell.accessibilityTraits = .button
            return cell
        }
    }

    // MARK: actions

    private func showLanguages() {
        let list = ModelsLanguagesScreenController(languages: model.catalogLanguages) { [weak self] tag in
            self?.showLanguage(tag)
        }
        navigationController?.pushViewController(list, animated: true)
    }

    private func showLanguage(_ tag: String) {
        navigationController?.pushViewController(
            ModelsScreenController(sharing: model, settings: settings, onlyLanguage: tag), animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        if indexPath.section == 0 {
            if let onlyLanguage { model.clearChoice(in: onlyLanguage) }
            else if NarrationRow(rawValue: indexPath.row) == .languages { showLanguages() }
            return
        }
        if onlyLanguage == nil { return showLanguage(languageItems[indexPath.row].language) }
        let group = groups[indexPath.section - 1]
        let row = group.rows[indexPath.row]
        switch row.availability {
        case .ready:
            if row.isChosen { model.clearChoice(in: group.language) }
            else if row.isExplicitOnly { Task { [weak self] in await self?.model.chooseExplicit(row, in: group.language) } }
            else { model.choose(row, in: group.language) }
        case .downloadable:
            Task { [weak self] in await self?.model.download(row, in: group.language) }
        case .needsConsent:
            let alert = UIAlertController(title: L10n.string("models.consent.title"),
                                          message: L10n.string("models.consent.message"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
        case .unavailable: break
        }
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard indexPath.section > 0 else { return }
        let group = groups[indexPath.section - 1]
        presentActions(for: group.rows[indexPath.row], in: group.language, source: indexPath)
    }

    private func hasActions(_ row: ModelsByLanguageViewState.Row, in language: String) -> Bool {
        row.availability == .ready && row.selection.engine != "edge" || model.progress[row.id] != nil
            || model.entry(forRow: row, in: language).map { model.isTermsAccepted(for: $0) && $0.licence.requiresAcceptance } == true
    }

    private func presentActions(for row: ModelsByLanguageViewState.Row, in language: String, source: IndexPath) {
        let alert = UIAlertController(title: row.title, message: nil, preferredStyle: .actionSheet)
        if model.progress[row.id] != nil {
            alert.addAction(UIAlertAction(title: L10n.string("settings.modelInstall.cancel"), style: .destructive) { [weak self] _ in
                Task { await self?.model.cancelDownload(row) }
            })
        }
        if row.availability == .ready {
            alert.addAction(UIAlertAction(title: model.libraryState(for: language).actionTitle(for: .preview), style: .default) { [weak self] _ in
                self?.preview(row, in: language)
            })
            if row.isChosen {
                alert.addAction(UIAlertAction(title: L10n.string("models.action.useAutomatic"), style: .default) { [weak self] _ in
                    self?.model.clearChoice(in: language)
                })
            }
            if row.selection.engine == "piper" {
                alert.addAction(UIAlertAction(title: model.libraryState(for: language).actionTitle(for: .remove), style: .destructive) { [weak self] _ in
                    self?.confirmRemoval(row, in: language)
                })
            }
        }
        if let entry = model.entry(forRow: row, in: language), entry.licence.requiresAcceptance, model.isTermsAccepted(for: entry) {
            alert.addAction(UIAlertAction(title: model.libraryState(for: language).actionTitle(for: .revokeTerms), style: .destructive) { [weak self] _ in
                self?.model.revokeTerms(for: entry)
            })
        }
        SettingsAlertPresentation.actionSheet(alert, on: self, tableView: tableView, source: source)
    }

    private func preview(_ row: ModelsByLanguageViewState.Row, in language: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let choice = try await model.auditionChoice(for: row, in: language)
                guard viewIfLoaded?.window != nil else { return }
                audition.present(selection: choice.selection, language: choice.language, on: self)
            } catch {
                guard viewIfLoaded?.window != nil else { return }
                SettingsAlertPresentation.info(on: self, title: L10n.string("voiceAudition.title"),
                                               message: AppErrorReporter.message(error, context: #function))
            }
        }
    }

    private func confirmRemoval(_ row: ModelsByLanguageViewState.Row, in language: String) {
        guard let entry = model.entry(forRow: row, in: language) else { return }
        SettingsAlertPresentation.confirmModelRemoval(entry, state: model.libraryState(for: language), on: self) { [weak self] in
            Task { [weak self] in
                guard let self else { return }
                do { try await model.remove(row, in: language) } catch {
                    SettingsAlertPresentation.info(on: self, title: L10n.string("settings.modelRemove.failed"),
                                                   message: AppErrorReporter.message(error, context: #function))
                }
            }
        }
    }

    private func presentPendingTermsIfNeeded() {
        guard let pending = model.pendingTerms, presentedViewController == nil else { return }
        let alert = UIAlertController(title: L10n.string("settings.modelTerms.acceptTitle"),
                                      message: L10n.string("settings.modelInstall.termsRequired"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel) { [weak self] _ in
            self?.model.declinePendingTerms()
        })
        alert.addAction(UIAlertAction(title: L10n.string("settings.modelTerms.accept"), style: .default) { [weak self] _ in
            Task { await self?.model.acceptPendingTerms() }
        })
        _ = pending
        present(alert, animated: true)
    }

    private func presentNewFailures() {
        guard presentedViewController == nil,
              let (id, message) = model.failures.first(where: { !shownFailures.contains($0.key) }) else { return }
        shownFailures.insert(id)
        SettingsAlertPresentation.info(on: self, title: L10n.string("settings.modelInstall.failed"), message: message)
    }
}
#endif
