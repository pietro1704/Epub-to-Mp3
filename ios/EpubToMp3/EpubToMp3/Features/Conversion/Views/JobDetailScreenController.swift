#if os(iOS)
import Combine
import UIKit

/// Shows the completed result of a manual embedded conversion.
@MainActor
final class JobDetailScreenController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case job
        case chapters
        case actions
    }

    private let miniPlayerClearance = MiniPlayerScrollClearance()
    private let localSnapshot: JobSnapshot
    private let player: AudioPlayer
    private let viewModel = JobDetailViewModel()
    private var viewModelObserver: AnyCancellable?

    init(localSnapshot: JobSnapshot, player: AudioPlayer, playbackClock _: PlaybackClock) {
        self.localSnapshot = localSnapshot
        self.player = player
        super.init(style: .insetGrouped)
        title = L10n.string("jobDetail.title")
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
            // A player already attached to this job adopts the completed
            // chapter list; another active book is never interrupted.
            guard let self, self.player.snapshot?.jobId == snapshot.jobId else { return }
            self.player.updateSnapshot(snapshot)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.showLocalSnapshot(localSnapshot)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        visibleSections.count
    }

    private var visibleSections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .job:
                return true
            case .chapters:
                return !playableChapters.isEmpty
            case .actions:
                return canPlay
            }
        }
    }

    private var playableChapters: [JobSnapshot.Chapter] {
        viewModel.snapshot?.playableChapters ?? []
    }

    private var canPlay: Bool { !playableChapters.isEmpty }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .job:
            return jobRows.count
        case .chapters:
            return playableChapters.count
        case .actions:
            return canPlay ? 1 : 0
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
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch visibleSections[indexPath.section] {
        case .job:
            return jobCell(for: indexPath.row)
        case .chapters:
            return chapterCell(for: indexPath.row)
        case .actions:
            return playCell(for: indexPath.row)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard visibleSections[indexPath.section] == .actions, canPlay else { return }
        openPlayer()
    }

    private func jobCell(for row: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: row, section: 0))
        var content = cell.defaultContentConfiguration()
        let rows = jobRows
        content.text = rows[row].0
        content.secondaryText = rows[row].1
        content.secondaryTextProperties.numberOfLines = 3
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.accessibilityLabel = content.text
        cell.accessibilityValue = content.secondaryText
        return cell
    }

    private var jobRows: [(String, String)] {
        [
            (L10n.string("jobDetail.book"), localSnapshot.bookTitle ?? ""),
            (L10n.string("jobDetail.state"), L10n.string("convert.completed")),
            (L10n.string("jobDetail.progress"), "100%"),
        ]
    }

    private func chapterCell(for row: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: row, section: 0))
        let chapters = playableChapters
        guard chapters.indices.contains(row) else { return cell }
        let chapter = chapters[row]
        var content = cell.defaultContentConfiguration()
        content.text = chapter.displayTitle
        content.secondaryText = L10n.string("convert.completed")
        content.secondaryTextProperties.numberOfLines = 1
        cell.contentConfiguration = content
        cell.accessoryType = chapter.isCompleted ? .checkmark : .none
        cell.selectionStyle = .none
        return cell
    }

    private func playCell(for row: Int) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Subtitle", for: IndexPath(row: row, section: 0))
        var content = cell.defaultContentConfiguration()
        content.text = L10n.string("player.play")
        content.image = UIImage(systemName: "play.circle.fill")
        cell.accessoryType = .disclosureIndicator
        cell.contentConfiguration = content
        return cell
    }

    /// Plays the local chapter files of this result. Manual conversions are
    /// not imported into the library, so this is their only playback entry.
    private func openPlayer() {
        guard let snapshot = viewModel.snapshot else { return }
        navigationController?.pushViewController(
            PlayerScreenController(
                snapshot: snapshot,
                backendBaseURL: nil,
                player: player
            ),
            animated: true
        )
    }
}
#endif
