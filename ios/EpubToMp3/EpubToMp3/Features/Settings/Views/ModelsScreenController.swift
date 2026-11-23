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
        let kind: ModelsByLanguageViewState.Kind
        let rows: [ModelsByLanguageViewState.Row]
        let isFirstOfLanguage: Bool
    }

    private let model: ModelsByLanguageModel
    private let settings: AppSettings
    private let audition = VoiceAuditionPresentation()
    private let focusLanguage: String?
    private var groups: [Group] = []
    private var observations: Set<AnyCancellable> = []
    private var shownFailures: Set<String> = []
    private var didFocus = false

    init(settings: AppSettings, source: ModelsByLanguageSource = SpeechModelsSource(),
         termsAcceptance: SpeechModelTermsAcceptanceStore = .init(), focusLanguage: String? = nil) {
        self.settings = settings
        self.focusLanguage = focusLanguage
        self.model = ModelsByLanguageModel(source: source, settings: settings, terms: termsAcceptance)
        super.init(style: .insetGrouped)
        title = L10n.string("models.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Model")
        tableView.accessibilityIdentifier = "models.table"
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &observations)
        Task { [weak self] in
            await self?.model.load()
            self?.refresh()
        }
    }

    private func refresh() {
        groups = model.state.sections.flatMap { section -> [Group] in
            var result: [Group] = []
            let local = section.local, online = section.online
            if !local.isEmpty { result.append(Group(language: section.language, kind: .local, rows: local, isFirstOfLanguage: true)) }
            if !online.isEmpty { result.append(Group(language: section.language, kind: .online, rows: online, isFirstOfLanguage: local.isEmpty)) }
            return result
        }
        tableView.reloadData()
        presentPendingTermsIfNeeded()
        presentNewFailures()
        if !didFocus, let focus = focusLanguage.map(SpeechPreferences.languageKey),
           let index = groups.firstIndex(where: { $0.language == focus }) {
            didFocus = true
            tableView.scrollToRow(at: IndexPath(row: 0, section: index), at: .top, animated: false)
        }
    }

    private func languageTitle(_ tag: String) -> String { Locale.current.localizedString(forLanguageCode: tag) ?? tag }

    // MARK: data source

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].rows.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let group = groups[section]
        return L10n.string(group.kind == .local ? "models.section.local" : "models.section.online", languageTitle(group.language))
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let group = groups[section]
        guard group.kind == .local || group.isFirstOfLanguage,
              model.state.sections.first(where: { $0.language == group.language })?.chosen == nil else { return nil }
        return group.kind == .local ? L10n.string("models.automatic") : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let group = groups[indexPath.section]
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

    // MARK: actions

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        let group = groups[indexPath.section]
        let row = group.rows[indexPath.row]
        switch row.availability {
        case .ready:
            if row.isChosen { model.clearChoice(in: group.language) } else { model.choose(row, in: group.language) }
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
        let group = groups[indexPath.section]
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
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
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
