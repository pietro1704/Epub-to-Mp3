#if os(iOS)
import Combine
import UIKit

@MainActor
final class JobDetailScreenController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case job
        case chapters
        case actions
        case error
        case payload
    }

    private enum Action: CaseIterable {
        case play
        case download
        case cancelDownloads
        case clearDownloads
        case logs
    }

    private let jobId: String
    private var settings: AppSettings
    private var library: LibraryStore
    private var player: AudioPlayer
    private var playbackClock: PlaybackClock
    private let viewModel = JobDetailViewModel()
    private var viewModelObserver: AnyCancellable?

    init(
        jobId: String,
        settings: AppSettings,
        library: LibraryStore,
        player: AudioPlayer,
        playbackClock: PlaybackClock
    ) {
        self.jobId = jobId
        self.settings = settings
        self.library = library
        self.player = player
        self.playbackClock = playbackClock
        super.init(style: .insetGrouped)
        title = L10n.string("jobDetail.title")
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Subtitle")
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.accessibilityLabel = L10n.string("jobDetail.title")
        viewModelObserver = viewModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.tableView.reloadData()
            }
        }
        viewModel.onSnapshot = { [weak self] snapshot in
            guard let self, self.player.snapshot?.jobId == snapshot.jobId else { return }
            self.player.updateSnapshot(snapshot)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.start(client: client, jobId: jobId)
        tableView.reloadData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController == nil {
            viewModel.stop()
        }
    }

    func update(settings: AppSettings, library: LibraryStore, player: AudioPlayer, playbackClock: PlaybackClock) {
        self.settings = settings
        self.library = library
        self.player = player
        self.playbackClock = playbackClock
        if isViewLoaded {
            tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.filter { section in
            switch section {
            case .job, .payload:
                return true
            case .chapters:
                return !(viewModel.snapshot?.playableChapters ?? []).isEmpty
            case .actions:
                return availableActions.isEmpty == false || viewModel.downloadProgressLabel != nil
            case .error:
                return viewModel.errorMessage != nil
            }
        }.count
    }

    private var visibleSections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .job, .payload:
                return true
            case .chapters:
                return !(viewModel.snapshot?.playableChapters ?? []).isEmpty
            case .actions:
                return availableActions.isEmpty == false || viewModel.downloadProgressLabel != nil
            case .error:
                return viewModel.errorMessage != nil
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .job:
            var count = 4
            if viewModel.snapshot?.bookTitle != nil { count += 1 }
            if viewModel.snapshot?.progressPercent != nil { count += 1 }
            return count
        case .chapters:
            return viewModel.snapshot?.playableChapters.count ?? 0
        case .actions:
            return availableActions.count + (viewModel.downloadProgressLabel == nil ? 0 : 1)
        case .error:
            return 1
        case .payload:
            return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .job:
            return L10n.string("jobDetail.job")
        case .chapters:
            return L10n.string("player.chapters")
        case .actions:
            return nil
        case .error:
            return L10n.string("player.error.title")
        case .payload:
            return L10n.string("jobDetail.latestEventPayload")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch visibleSections[indexPath.section] {
        case .job:
            return jobCell(for: indexPath.row)
        case .chapters:
            return chapterCell(for: indexPath.row)
        case .actions:
            return actionCell(for: indexPath.row)
        case .error:
            return errorCell()
        case .payload:
            return payloadCell()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard visibleSections[indexPath.section] == .actions else { return }
        let actions = availableActions
        guard indexPath.row < actions.count else { return }
        switch actions[indexPath.row] {
        case .play:
            openPlayer()
        case .download:
            viewModel.downloadAll(baseURL: settings.resolvedBaseURL)
        case .cancelDownloads:
            viewModel.cancelDownloads()
        case .clearDownloads:
            viewModel.clearDownloads()
        case .logs:
            openLogs()
        }
        tableView.reloadData()
    }

    private var availableActions: [Action] {
        guard viewModel.snapshot?.playableChapters.isEmpty == false else { return [] }
        var actions: [Action] = [.play, .download, .logs]
        if viewModel.downloadState == .downloading {
            actions.insert(.cancelDownloads, at: 2)
        }
        if viewModel.downloadState == .completed {
            actions.insert(.clearDownloads, at: 2)
        }
        return actions
    }

    private func jobCell(for row: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: row, section: 0))
        var content = cell.defaultContentConfiguration()
        let rows = jobRows
        content.text = rows[row].0
        content.secondaryText = rows[row].1
        content.secondaryTextProperties.numberOfLines = 3
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText
        return cell
    }

    private var jobRows: [(String, String)] {
        var rows = [
            (L10n.string("jobDetail.id"), jobId),
            (L10n.string("jobDetail.state"), viewModel.snapshot?.state ?? "—"),
            (L10n.string("jobDetail.eventsReceived"), "\(viewModel.receivedCount)"),
        ]
        if let title = viewModel.snapshot?.bookTitle {
            rows.insert((L10n.string("jobDetail.book"), title), at: 2)
        }
        if let pct = viewModel.snapshot?.progressPercent {
            rows.append((L10n.string("jobDetail.progress"), unsafe String(format: "%.0f%%", pct)))
        }
        rows.append((
            L10n.string("jobDetail.streaming"),
            viewModel.isStreaming ? L10n.string("jobDetail.live") : String(localized: "jobDetail.idle")
        ))
        return rows
    }

    private func chapterCell(for row: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: row, section: 0))
        guard let chapter = viewModel.snapshot?.playableChapters[row] else { return cell }
        var content = cell.defaultContentConfiguration()
        content.text = chapter.displayTitle
        content.secondaryText = chapter.downloadUrl
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessoryType = chapter.isCompleted ? .checkmark : .none
        cell.selectionStyle = .none
        return cell
    }

    private func actionCell(for row: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: row, section: 0))
        var content = cell.defaultContentConfiguration()
        let actions = availableActions
        if row < actions.count {
            switch actions[row] {
            case .play:
                content.text = L10n.string("player.play")
                content.image = UIImage(systemName: "play.circle.fill")
            case .download:
                content.text = L10n.string("jobDetail.downloadAll")
                content.image = UIImage(systemName: "arrow.down.circle")
            case .cancelDownloads:
                content.text = L10n.string("chapterList.cancelDownloads")
                content.image = UIImage(systemName: "xmark.circle")
            case .clearDownloads:
                content.text = L10n.string("chapterList.removeDownloads")
                content.image = UIImage(systemName: "trash")
            case .logs:
                content.text = L10n.string("jobDetail.openLogs")
                content.image = UIImage(systemName: "doc.text.magnifyingglass")
            }
            cell.accessoryType = .disclosureIndicator
        } else {
            content.text = viewModel.downloadProgressLabel
            content.secondaryText = nil
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    private func errorCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: 0, section: 0))
        var content = cell.defaultContentConfiguration()
        content.text = viewModel.errorMessage
        content.image = UIImage(systemName: "exclamationmark.triangle")
        content.imageProperties.tintColor = .systemRed
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText
        return cell
    }

    private func payloadCell() -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: 0, section: 0))
        var content = cell.defaultContentConfiguration()
        content.text = viewModel.latestPayload.isEmpty
            ? String(localized: "jobDetail.waitingFirstEvent")
            : viewModel.latestPayload
        content.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func openPlayer() {
        guard let snapshot = viewModel.snapshot else { return }
        navigationController?.pushViewController(
            PlayerScreenController(
                snapshot: snapshot,
                backendBaseURL: settings.resolvedBaseURL,
                player: player,
                playbackClock: playbackClock
            ),
            animated: true
        )
    }

    private func openLogs() {
        navigationController?.pushViewController(
            LogsScreenController(settings: settings, jobId: jobId),
            animated: true
        )
    }
}
#endif
