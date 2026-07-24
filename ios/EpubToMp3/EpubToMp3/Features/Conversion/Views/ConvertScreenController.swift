#if os(iOS)
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

    private let settings: AppSettings
    private let library: LibraryStore
    private let player: AudioPlayer
    private let playbackClock: PlaybackClock
    private let viewModel = ConvertViewModel()

    private static let acceptedTypes: [UTType] = {
        var types: [UTType] = [.epub, .pdf]
        if let zip = UTType("org.idpf.epub-container") { types.append(zip) }
        return types
    }()

    init(settings: AppSettings, library: LibraryStore, player: AudioPlayer, playbackClock: PlaybackClock) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playbackClock = playbackClock
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

    private var client: APIClient? {
        settings.resolvedBaseURL.map(APIClient.init(baseURL:))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        tableView.register(IOSInlineTextFieldCell.self, forCellReuseIdentifier: "TextField")
        tableView.register(IOSSwitchCell.self, forCellReuseIdentifier: "Switch")
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
            return 3
        case .chapters:
            return 1
        case .flags:
            return 3
        case .result:
            var count = 0
            if viewModel.submittedJobId != nil { count += 2 }
            if viewModel.error != nil { count += 1 }
            return count
        case .action:
            return 1
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

        switch section {
        case .file:
            return fileCell(for: indexPath)
        case .engine:
            return engineCell(for: indexPath)
        case .chapters:
            return chaptersCell()
        case .flags:
            return flagCell(for: indexPath)
        case .result:
            return resultCell(for: indexPath)
        case .action:
            return actionCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else { return }
        switch section {
        case .file:
            if indexPath.row == 1 {
                presentPicker()
            }
        case .result:
            if viewModel.submittedJobId != nil && indexPath.row == 1 {
                openSubmittedJob()
            }
        case .action:
            submit()
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
        return cell
    }

    private func engineCell(for indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("convert.engine")
            cell.contentConfiguration = content

            let control = UISegmentedControl(items: [
                "Edge",
                "Piper",
                "Coqui",
            ])
            control.selectedSegmentIndex = ["edge", "piper", "coqui"].firstIndex(of: viewModel.engine) ?? 0
            control.addAction(UIAction(handler: { [weak self] _ in
                self?.viewModel.engine = ["edge", "piper", "coqui"][control.selectedSegmentIndex]
            }), for: .valueChanged)
            cell.accessoryView = control
            cell.selectionStyle = .none
            return cell
        }

        let cell = tableView.dequeueReusableCell(withIdentifier: "TextField", for: indexPath) as! IOSInlineTextFieldCell
        if indexPath.row == 1 {
            cell.configure(
                title: L10n.string("convert.voiceOptional"),
                value: viewModel.voice,
                placeholder: L10n.string("convert.voiceOptional")
            )
            cell.onTextChanged = { [weak self] text in self?.viewModel.voice = text }
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

    private func resultCell(for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        var row = indexPath.row
        if let jobId = viewModel.submittedJobId {
            if row == 0 {
                content.text = L10n.string("convert.jobSubmitted", jobId)
                content.image = UIImage(systemName: "checkmark.seal.fill")
                cell.selectionStyle = .none
                cell.accessoryType = .none
                cell.contentConfiguration = content
                return cell
            }
            row -= 1
            if row == 0 {
                content.text = L10n.string("convert.openProgress")
                content.image = UIImage(systemName: "arrow.right.circle")
                cell.accessoryType = .disclosureIndicator
                cell.contentConfiguration = content
                return cell
            }
            row -= 1
        }
        if row == 0, let error = viewModel.error {
            content.text = error
            content.image = UIImage(systemName: "exclamationmark.triangle")
            content.imageProperties.tintColor = .systemRed
            content.secondaryText = nil
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    private func actionCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: IndexPath(row: 0, section: 0))
        var content = cell.defaultContentConfiguration()
        content.text = viewModel.isSubmitting
            ? L10n.string("convert.submitting")
            : L10n.string("convert.startConversion")
        content.textProperties.alignment = .center
        content.textProperties.color = viewModel.selectedFile == nil ? .secondaryLabel : view.tintColor
        if viewModel.isSubmitting {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            cell.accessoryView = spinner
        } else {
            cell.accessoryView = nil
        }
        cell.contentConfiguration = content
        cell.selectionStyle = (viewModel.selectedFile == nil || viewModel.isSubmitting) ? .none : .default
        return cell
    }

    private func presentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: Self.acceptedTypes, asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        viewModel.selectedFile = url
        reloadData()
    }

    private func submit() {
        guard viewModel.selectedFile != nil, !viewModel.isSubmitting else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.submit(client: self.client)
            self.reloadData()
        }
    }

    private func openSubmittedJob() {
        guard let jobId = viewModel.submittedJobId else { return }
        let detail = JobDetailScreenController(
            jobId: jobId,
            settings: settings,
            library: library,
            player: player,
            playbackClock: playbackClock
        )
        detail.title = L10n.string("jobDetail.title")
        navigationController?.pushViewController(detail, animated: true)
    }

    private func reloadData() {
        tableView.reloadData()
    }
}
#endif
