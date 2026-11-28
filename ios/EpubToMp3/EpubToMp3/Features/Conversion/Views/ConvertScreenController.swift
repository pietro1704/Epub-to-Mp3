#if os(iOS)
import Combine
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ConvertScreenController: UITableViewController, UIDocumentPickerDelegate {
    private enum Section: Int, CaseIterable {
        case file
        case engine
        case chapters
        case flags
        case result
        case action
    }

    private let miniPlayerClearance = MiniPlayerScrollClearance()
    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock
    private let preselectedFileURL: URL?
    private let preselectedBookID: String?
    private let viewModel: ConvertViewModel
    private var submissionObserver: AnyCancellable?
    private var startedWholeBookConversion = false
    private var delivery = ConvertDeliveryState()
    private weak var exportPicker: UIDocumentPickerViewController?
    private var exportStaging: URL?

    private static let acceptedTypes: [UTType] = SupportedImportTypes.all

    /// Library downloads reuse the existing conversion form with the source
    /// already selected. The standalone Convert tab keeps its document picker.
    init(
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        playbackClock: PlaybackClock,
        preselectedFileURL: URL? = nil,
        preselectedBookID: String? = nil,
        viewModel: ConvertViewModel? = nil
    ) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playbackClock = playbackClock
        self.preselectedFileURL = preselectedFileURL
        self.preselectedBookID = preselectedBookID
        self.viewModel = viewModel ?? ConvertViewModel()
        super.init(style: .insetGrouped)
        title = L10n.string("convert.title")
        tabBarItem = UITabBarItem(
            title: L10n.string("convert.title"),
            image: UIImage(systemName: "wand.and.stars"),
            tag: 0
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }


    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        miniPlayerClearance.updateForShell(self)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        viewModel.inheritedPreferences = settings.ttsPreferences
        if viewModel.usesPreferences { viewModel.engine = settings.primaryEngine }
        viewModel.modelsRoot = LocalSpeechModelReadiness.ttsModelsRoot()?.path
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.accessibilityLabel = L10n.string("convert.title")
        if let preselectedFileURL {
            viewModel.selectedFile = preselectedFileURL
        }
        tableView.register(IOSContentCell.self, forCellReuseIdentifier: "Cell")
        tableView.register(IOSInlineTextFieldCell.self, forCellReuseIdentifier: "TextField")
        tableView.register(IOSSwitchCell.self, forCellReuseIdentifier: "Switch")
        tableView.register(IOSContentCell.self, forCellReuseIdentifier: "SilenceTrim")
        submissionObserver = viewModel.session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadData() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.inheritedPreferences = settings.ttsPreferences
        if viewModel.usesPreferences { viewModel.engine = settings.primaryEngine }
        viewModel.modelsRoot = LocalSpeechModelReadiness.ttsModelsRoot()?.path
        tableView.reloadSections(IndexSet([Section.engine.rawValue, Section.flags.rawValue]), with: .none)
    }

    func refreshFromStores() {
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .file:
            return 2
        case .engine:
            return 4
        case .chapters:
            return 1
        case .flags:
            return 4
        case .result:
            return resultRows.count
        case .action:
            return viewModel.isSubmitting ? 2 : 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .file: return L10n.string("convert.file")
        case .engine: return L10n.string("convert.engine")
        case .chapters: return L10n.string("convert.chapters")
        case .flags: return L10n.string("convert.flags")
        case .result:
            return (viewModel.submittedJobId != nil || viewModel.error != nil) ? L10n.string("jobDetail.title") : nil
        case .action: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        let cell: UITableViewCell
        switch section {
        case .file:
            cell = fileCell(for: indexPath)
        case .engine:
            cell = engineCell(for: indexPath)
        case .chapters:
            cell = chaptersCell()
        case .flags:
            cell = flagCell(for: indexPath)
        case .result:
            cell = resultCell(for: indexPath)
        case .action:
            cell = actionCell(for: indexPath)
        }
        switch section {
        case .file, .engine, .chapters, .flags:
            cell.isUserInteractionEnabled = !viewModel.isSubmitting
        case .result, .action:
            cell.isUserInteractionEnabled = true
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else { return }
        if viewModel.isSubmitting, section != .action, section != .result { return }
        switch section {
        case .file:
            if indexPath.row == 1 {
                presentPicker()
            }
        case .result:
            guard resultRows.indices.contains(indexPath.row) else { break }
            switch resultRows[indexPath.row] {
            case .open: openSubmittedJob()
            case .addToLibrary: addResultToLibrary()
            case .export: chooseExport(from: tableView.rectForRow(at: indexPath))
            case .completed, .delivery, .error: break
            }
        case .action:
            if indexPath.row == 1 { viewModel.cancel() } else { submit() }
        case .engine where indexPath.row == 0:
            let alert = UIAlertController(title: L10n.string("settings.audioEngineChoice"), message: nil, preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: L10n.string("convert.usePreferences"), style: .default) { [weak self] _ in
                self?.viewModel.usesPreferences = true
                self?.reloadData()
            })
            for engine in TtsSelection.selectableEngines {
                alert.addAction(UIAlertAction(title: TtsSelection.displayName(forEngine: engine) ?? engine,
                                              style: .default) { [weak self] _ in
                    self?.viewModel.usesPreferences = false
                    self?.viewModel.engine = engine
                    self?.viewModel.allowSecondary = false
                    self?.reloadData()
                })
            }
            alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
            alert.popoverPresentationController?.sourceView = tableView
            alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
            present(alert, animated: true)
        case .flags where indexPath.row == 3:
            present(SilenceTrimControl.picker(from: tableView, at: indexPath) { [weak self] level in
                self?.viewModel.silenceTrimOverride = level
                self?.reloadData()
            }, animated: true)
        case .engine, .chapters, .flags:
            break
        }
    }

    private func fileCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.row == 0 {
            content.text = L10n.string("convert.selected")
            if let file = viewModel.selectedFile {
                content.secondaryText = "\(file.lastPathComponent)\n\(file.path)"
            } else {
                content.secondaryText = L10n.string("convert.noFilePicked")
            }
            content.secondaryTextProperties.numberOfLines = 2
            cell.selectionStyle = .none
        } else {
            content.text = viewModel.selectedFile == nil
                ? L10n.string("convert.pickFile")
                : L10n.string("convert.changeFile")
            content.image = UIImage(systemName: "doc.badge.plus")
            cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = content
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText
        if indexPath.row == 1 { cell.accessibilityHint = L10n.string("convert.chooseFileHint") }
        return cell
    }

    private func engineCell(for indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("settings.audioEngineChoice")
            content.secondaryText = viewModel.usesPreferences ? L10n.string("convert.usePreferences") : TtsSelection.displayName(forEngine: viewModel.engine)
            cell.accessibilityIdentifier = "convert.tts.primary"
            cell.accessibilityValue = content.secondaryText
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }
        if indexPath.row == 3 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
            let canSelectSecondary = !viewModel.usesPreferences && viewModel.distinctManualSecondary != nil
            cell.configure(title: L10n.string("convert.allowSecondary"), subtitle: L10n.string("convert.allowSecondaryDescription"), isOn: viewModel.usesPreferences ? viewModel.inheritedPreferences?.secondary != nil : canSelectSecondary && viewModel.allowSecondary, accessibilityIdentifier: "convert.tts.useSecondary")
            cell.isUserInteractionEnabled = canSelectSecondary
            cell.toggleSwitch.isEnabled = canSelectSecondary
            cell.onValueChanged = { [weak self] in self?.viewModel.allowSecondary = $0 }
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "TextField", for: indexPath) as! IOSInlineTextFieldCell
        if indexPath.row == 1 {
            cell.configure(
                title: L10n.string("convert.voiceOptional"),
                value: viewModel.voice,
                placeholder: L10n.string("convert.voiceOptional")
            )
            cell.onTextChanged = { [weak self] text in
                guard let self else { return }
                if self.viewModel.usesPreferences {
                    self.viewModel.engine = self.viewModel.inheritedPreferences?.primary.engine ?? self.settings.primaryEngine
                    self.viewModel.allowSecondary = false
                }
                self.viewModel.voice = text
                self.viewModel.usesPreferences = false
                self.tableView.reloadRows(at: [IndexPath(row: 0, section: Section.engine.rawValue),
                                              IndexPath(row: 3, section: Section.engine.rawValue)], with: .none)
            }
        } else {
            cell.configure(
                title: L10n.string("convert.languageOptional"),
                value: viewModel.language,
                placeholder: L10n.string("convert.languageOptional"),
                keyboardType: .alphabet,
                autocapitalization: .none
            )
            cell.onTextChanged = { [weak self] text in self?.viewModel.language = text }
        }
        return cell
    }

    private func chaptersCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "TextField", for: IndexPath(row: 0, section: 0)) as! IOSInlineTextFieldCell
        cell.configure(
            title: L10n.string("convert.chapterRangeOptional"),
            value: viewModel.chapters,
            placeholder: L10n.string("convert.chapterRangeHelp"),
            keyboardType: .numbersAndPunctuation,
            autocapitalization: .none
        )
        cell.onTextChanged = { [weak self] text in self?.viewModel.chapters = text }
        return cell
    }

    private func flagCell(for indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == 3 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "SilenceTrim", for: indexPath)
            SilenceTrimControl.configure(cell, level: viewModel.silenceTrim,
                                         accessibilityIdentifier: "convert.silenceTrim")
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "Switch", for: indexPath) as! IOSSwitchCell
        switch indexPath.row {
        case 0:
            cell.configure(title: L10n.string("convert.clearCache"), isOn: viewModel.clearCache)
            cell.onValueChanged = { [weak self] isOn in self?.viewModel.clearCache = isOn }
        case 1:
            cell.configure(title: L10n.string("convert.forceReprocess"), isOn: viewModel.forceReprocess)
            cell.onValueChanged = { [weak self] isOn in self?.viewModel.forceReprocess = isOn }
        default:
            cell.configure(title: L10n.string("convert.maxPerformance"), isOn: viewModel.maxPerformance)
            cell.onValueChanged = { [weak self] isOn in self?.viewModel.maxPerformance = isOn }
        }
        return cell
    }

    private enum ResultRow {
        case completed, open, addToLibrary, export, delivery, error
    }

    private var resultRows: [ResultRow] {
        var rows: [ResultRow] = []
        if viewModel.submittedJobId != nil {
            rows += [.completed, .open]
            if delivery.canAddToLibrary(library: library) { rows.append(.addToLibrary) }
            if delivery.isReady { rows.append(.export) }
            if delivery.message != nil { rows.append(.delivery) }
        }
        if viewModel.error != nil { rows.append(.error) }
        return rows
    }

    private func resultCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.accessibilityIdentifier = nil
        cell.accessibilityLabel = nil
        cell.accessibilityHint = nil
        cell.accessibilityTraits = .staticText
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        guard resultRows.indices.contains(indexPath.row) else { return cell }
        func button(_ key: String, symbol: String, identifier: String, enabled: Bool) {
            content.text = L10n.string(key)
            content.image = UIImage(systemName: symbol)
            content.textProperties.color = enabled ? .label : .secondaryLabel
            cell.selectionStyle = enabled ? .default : .none
            cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
            cell.accessibilityIdentifier = identifier
        }
        switch resultRows[indexPath.row] {
        case .completed:
            content.text = L10n.string("convert.completed")
            content.image = UIImage(systemName: "checkmark.seal.fill")
        case .open:
            content.text = L10n.string("convert.openResult")
            content.image = UIImage(systemName: "arrow.right.circle")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        case .addToLibrary:
            button("convert.addToLibrary", symbol: "books.vertical",
                   identifier: "convert.addToLibrary", enabled: !delivery.isBusy)
        case .export:
            let hasAudio = delivery.audiobook(library: library) != nil
            button("convert.export", symbol: "square.and.arrow.up",
                   identifier: "convert.export", enabled: hasAudio && !delivery.isBusy)
            content.secondaryText = hasAudio ? nil : L10n.string("convert.export.needsPiper")
        case .delivery:
            content.text = delivery.message
            content.textProperties.numberOfLines = 0
            cell.accessibilityIdentifier = "convert.delivery"
        case .error:
            content.text = viewModel.error
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemRed
        }
        cell.contentConfiguration = content
        return cell
    }

    private func actionCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil
        if indexPath.row == 1 {
            let canCancel = viewModel.isSubmitting && viewModel.session.phase != .cancelling
            content.text = L10n.string("convert.cancel")
            content.textProperties.color = canCancel ? view.tintColor : .secondaryLabel
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "convert.cancel"
            cell.accessibilityLabel = content.text
            cell.accessibilityHint = nil
            cell.accessibilityTraits = canCancel ? .button : [.button, .notEnabled]
            cell.selectionStyle = canCancel ? .default : .none
            return cell
        }
        content.text = ManualConversionPresentation.title(for: viewModel.session)
        content.secondaryText = ManualConversionPresentation.detail(for: viewModel.session)
        content.textProperties.alignment = .center
        content.textProperties.color = viewModel.isSubmitting ? .label
            : (viewModel.selectedFile == nil ? .secondaryLabel : view.tintColor)
        if viewModel.isSubmitting {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        } else {
            cell.accessoryView = nil
        }
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "convert.submit"
        cell.accessibilityLabel = content.text
        cell.accessibilityTraits = viewModel.isSubmitting ? [.staticText, .updatesFrequently]
            : (viewModel.selectedFile == nil ? [.button, .notEnabled] : .button)
        cell.accessibilityHint = viewModel.isSubmitting ? nil : (viewModel.selectedFile == nil
            ? L10n.string("convert.pickFileFirstHint") : L10n.string("convert.startConversionHint"))
        cell.selectionStyle = (viewModel.selectedFile == nil || viewModel.isSubmitting) ? .none : .default
        return cell
    }

    private func presentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.acceptedTypes, asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - Delivery of a finished conversion

    /// Reads what the finished job can be delivered as; a source already in the library
    /// gets the audio linked, as on the Mac.
    func prepareDelivery(source: URL) async {
        guard let result = viewModel.session.result, delivery.jobID != result.jobID,
              let snapshot = try? result.snapshot() else { return }
        guard let sourceID = try? await Task.detached(operation: {
            try ConvertViewModel.sourceIdentity(of: source)
        }).value, viewModel.submittedJobId == result.jobID else { return }
        delivery = ConvertDeliveryState(jobID: result.jobID, source: source, sourceID: sourceID, snapshot: snapshot)
        if library.books.contains(where: { $0.id == sourceID }) {
            library.recordConversion(jobId: result.jobID, for: sourceID)
        }
        reloadData()
    }

    private func addResultToLibrary() {
        guard !delivery.isBusy, let jobID = delivery.jobID, let source = delivery.source else { return }
        delivery.isBusy = true
        reloadData()
        Task { [weak self] in
            guard let self else { return }
            let message: String
            do {
                try await ManualConversionDelivery.addToLibrary(source: source, jobID: jobID, library: self.library)
                message = L10n.string("convert.addedToLibrary")
            } catch {
                message = AppErrorReporter.message(error, context: "Add converted book to library")
            }
            self.finishDelivery(jobID: jobID, message: message)
        }
    }

    private func finishDelivery(jobID: String, message: String?) {
        guard delivery.jobID == jobID else { return }
        delivery.isBusy = false
        delivery.message = message
        reloadData()
    }

    /// Layout, then format; the destination is chosen in Files after the files are written.
    private func chooseExport(from rect: CGRect) {
        guard !delivery.isBusy, delivery.audiobook(library: library) != nil else { return }
        let layouts = ManualConversionDelivery.Layout.allCases.map { layout in
            (L10n.string(layout.titleKey), { [weak self] in self?.chooseExportFormat(layout, from: rect) ?? () })
        }
        presentChoices(title: L10n.string("convert.export.layout"), choices: layouts, from: rect)
    }

    private func chooseExportFormat(_ layout: ManualConversionDelivery.Layout, from rect: CGRect) {
        let formats = ManualConversionDelivery.Format.allCases.map { format in
            (format.title, { [weak self] in self?.export(layout: layout, format: format) ?? () })
        }
        presentChoices(title: L10n.string("convert.export.format"), choices: formats, from: rect)
    }

    private func presentChoices(title: String, choices: [(String, () -> Void)], from rect: CGRect) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for (name, run) in choices {
            sheet.addAction(UIAlertAction(title: name, style: .default) { _ in run() })
        }
        sheet.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = rect
        present(sheet, animated: true)
    }

    private func export(layout: ManualConversionDelivery.Layout, format: ManualConversionDelivery.Format) {
        guard !delivery.isBusy, let jobID = delivery.jobID,
              let book = delivery.audiobook(library: library) else { return }
        delivery.isBusy = true
        delivery.message = L10n.string("convert.export.running")
        reloadData()
        Task { [weak self] in
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("ManualExportShare-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let files = try await ManualConversionDelivery.export(book, layout: layout, format: format, to: staging)
                guard let self, self.delivery.jobID == jobID, self.view.window != nil else {
                    try? FileManager.default.removeItem(at: staging)
                    self?.finishDelivery(jobID: jobID, message: nil)
                    return
                }
                let picker = UIDocumentPickerViewController(forExporting: files, asCopy: true)
                picker.delegate = self
                self.exportPicker = picker
                self.exportStaging = staging
                self.present(picker, animated: true)
            } catch {
                try? FileManager.default.removeItem(at: staging)
                self?.finishDelivery(jobID: jobID, message: L10n.string("convert.export.failed") + " "
                    + AppErrorReporter.message(error, context: "Export converted audio"))
            }
        }
    }

    private func finishExport(savedFiles: Int?) {
        if let exportStaging { try? FileManager.default.removeItem(at: exportStaging) }
        exportStaging = nil
        exportPicker = nil
        guard let jobID = delivery.jobID else { return }
        finishDelivery(jobID: jobID, message: savedFiles.map(ManualConversionDelivery.doneMessage(fileCount:)))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if controller === exportPicker { finishExport(savedFiles: nil) }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if controller === exportPicker { return finishExport(savedFiles: urls.count) }
        guard let url = urls.first else { return }
        viewModel.recoverySelection = nil
        viewModel.recoveryLanguage = nil
        viewModel.selectedFile = url
        reloadData()
    }

    func startWholeBookConversion() {
        guard !startedWholeBookConversion else { return }
        startedWholeBookConversion = true
        loadViewIfNeeded()
        viewModel.chapters = ""
        submit()
    }

    private func submit() {
        guard viewModel.selectedFile != nil, !viewModel.isSubmitting else { return }
        view.endEditing(true)
        Task { [weak self] in
            guard let self else { return }
            let converted = self.viewModel.selectedFile
            await self.viewModel.submit(
                player: self.player
            )
            if let jobId = self.viewModel.submittedJobId,
               let bookID = self.preselectedBookID {
                self.library.recordConversion(jobId: jobId, for: bookID)
            }
            self.reloadData()
            if let converted { await self.prepareDelivery(source: converted) }
            if let failure = self.viewModel.session.failure, BookLanguageUncertain.decode(failure) != nil,
               let file = self.viewModel.selectedFile {
                let requestID = self.viewModel.session.requestID
                do {
                    let bookID = try await Task.detached { try ConvertViewModel.sourceIdentity(of: file) }.value
                    let recovered = await BookLanguagePicker.recover(failure, bookID: bookID, isCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.navigationController?.topViewController === self
                            && self.viewModel.selectedFile == file && self.viewModel.session.requestID == requestID && !self.viewModel.isSubmitting
                    })
                    if recovered { self.submit() }
                } catch { _ = AppErrorReporter.message(error, context: "Identify conversion source") }
            } else if let failure = self.viewModel.session.failure, TtsLanguageMismatch.decode(failure) != nil {
                let file = self.viewModel.selectedFile
                let requestID = self.viewModel.session.requestID
                let choice = await TtsRecoveryAlert.choose(for: failure, isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.navigationController?.topViewController === self
                        && self.viewModel.selectedFile == file && self.viewModel.session.requestID == requestID && !self.viewModel.isSubmitting
                })
                if let choice {
                    self.viewModel.recoverySelection = choice.candidate
                    self.viewModel.recoveryLanguage = choice.language
                    self.submit()
                }
            }
        }
    }

    private func openSubmittedJob() {
        guard let result = viewModel.session.result else { return }
        let snapshot: JobSnapshot
        do { snapshot = try result.snapshot() }
        catch {
            let alert = UIAlertController(title: L10n.string("convert.title"),
                message: AppErrorReporter.message(error, context: "Manual conversion result"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert, animated: true)
            return
        }
        let detail = JobDetailScreenController(
            localSnapshot: snapshot,
            player: player,
            playbackClock: playbackClock
        )
        detail.title = L10n.string("convert.resultTitle")
        navigationController?.pushViewController(detail, animated: true)
    }

    private func reloadData() {
        tableView.reloadData()
    }
}
#endif
