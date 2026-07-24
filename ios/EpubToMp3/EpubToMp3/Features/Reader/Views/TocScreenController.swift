#if os(iOS)
import UIKit

@MainActor
final class TocScreenController: UITableViewController {
    private struct Row {
        let title: String
        let zeroBasedIndex: Int
        let charCount: Int?
        let isCurrent: Bool
        let audioReady: Bool
        let downloaded: Bool
    }

    private var fulltext: EbookFulltext?
    private var snapshot: JobSnapshot
    private var currentChapterIndex: Int
    private var readingChapterIndex: Int?
    private var onJump: (Int) -> Void
    private var onDownload: ((Int) -> Void)?
    private var onDownloadAll: (() -> Void)?
    private var onCancelDownloads: (() -> Void)?
    private var onClearDownloads: (() -> Void)?
    private var locallyDownloaded: Set<Int> = []

    init(
        fulltext: EbookFulltext?,
        snapshot: JobSnapshot,
        currentChapterIndex: Int,
        readingChapterIndex: Int?,
        onJump: @escaping (Int) -> Void,
        onDownload: ((Int) -> Void)?,
        onDownloadAll: (() -> Void)?,
        onCancelDownloads: (() -> Void)?,
        onClearDownloads: (() -> Void)?
    ) {
        self.fulltext = fulltext
        self.snapshot = snapshot
        self.currentChapterIndex = currentChapterIndex
        self.readingChapterIndex = readingChapterIndex
        self.onJump = onJump
        self.onDownload = onDownload
        self.onDownloadAll = onDownloadAll
        self.onCancelDownloads = onCancelDownloads
        self.onClearDownloads = onClearDownloads
        super.init(style: .plain)
        title = L10n.string("player.chapters")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.string("player.close"),
            style: .done,
            target: self,
            action: #selector(doneTapped)
        )
        configureMoreMenu()
        refreshDownloaded()
    }

    func update(
        fulltext: EbookFulltext?,
        snapshot: JobSnapshot,
        currentChapterIndex: Int,
        readingChapterIndex: Int?,
        onJump: @escaping (Int) -> Void,
        onDownload: ((Int) -> Void)?,
        onDownloadAll: (() -> Void)?,
        onCancelDownloads: (() -> Void)?,
        onClearDownloads: (() -> Void)?
    ) {
        self.fulltext = fulltext
        self.snapshot = snapshot
        self.currentChapterIndex = currentChapterIndex
        self.readingChapterIndex = readingChapterIndex
        self.onJump = onJump
        self.onDownload = onDownload
        self.onDownloadAll = onDownloadAll
        self.onCancelDownloads = onCancelDownloads
        self.onClearDownloads = onClearDownloads
        configureMoreMenu()
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let row = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        var secondary: [String] = []
        if let charCount = row.charCount {
            secondary.append(L10n.string("toc.charsCount", charCount))
        }
        if row.downloaded {
            secondary.append(L10n.string("toc.downloaded"))
        } else if !row.audioReady {
            secondary.append(L10n.string("toc.textOnly"))
        }
        content.secondaryText = secondary.joined(separator: " · ")
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = row.isCurrent ? .checkmark : .none
        cell.accessoryView = makeAccessoryView(for: row)
        cell.selectionStyle = .default
        cell.isUserInteractionEnabled = true
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        onJump(rows[indexPath.row].zeroBasedIndex)
        dismiss(animated: true)
    }

    private var rows: [Row] {
        if let fulltext, !fulltext.chapters.isEmpty {
            return fulltext.chapters.map { chapter in
                let zeroBased = chapter.index - 1
                return Row(
                    title: chapter.displayTitle,
                    zeroBasedIndex: zeroBased,
                    charCount: chapter.charCount,
                    isCurrent: isCurrent(zeroBasedIndex: zeroBased),
                    audioReady: snapshot.playableChapters.contains {
                        $0.index == zeroBased && $0.downloadUrl != nil
                    },
                    downloaded: locallyDownloaded.contains(zeroBased)
                )
            }
        }
        return snapshot.playableChapters.map { chapter in
            Row(
                title: chapter.displayTitle,
                zeroBasedIndex: chapter.index,
                charCount: chapter.chars,
                isCurrent: isCurrent(zeroBasedIndex: chapter.index),
                audioReady: chapter.downloadUrl != nil,
                downloaded: locallyDownloaded.contains(chapter.index)
            )
        }
    }

    private func isCurrent(zeroBasedIndex idx: Int) -> Bool {
        let audioActive = currentChapterIndex >= 0
        let audioMatch = audioActive && currentChapterIndex == idx
        let readingMatch = readingChapterIndex.map { $0 == idx } ?? false
        if audioActive {
            return audioMatch || readingMatch
        }
        return readingMatch
    }

    private func refreshDownloaded() {
        // `Task.detached` does not inherit the enclosing `@MainActor`
        // isolation, so `snapshot` (a MainActor-isolated property) must be
        // captured into a plain local before crossing into the detached
        // closure — referencing `self.snapshot` directly from inside it is
        // both a capture-semantics error and an actor-isolation violation.
        let jobId = snapshot.jobId
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.locallyDownloaded = await Task.detached(priority: .utility) {
                DownloadManager.locallyDownloadedIndices(for: jobId)
            }.value
            self.tableView.reloadData()
        }
    }

    private func configureMoreMenu() {
        let actions = [
            onDownloadAll.map { action in
                UIAction(title: L10n.string("player.downloadAll"), image: UIImage(systemName: "arrow.down.circle")) { _ in
                    action()
                }
            },
            onCancelDownloads.map { action in
                UIAction(title: L10n.string("chapterList.cancelDownloads"), image: UIImage(systemName: "xmark.circle")) { _ in
                    action()
                }
            },
            onClearDownloads.map { action in
                UIAction(title: L10n.string("chapterList.removeDownloads"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    action()
                }
            }
        ].compactMap { $0 }
        navigationItem.leftBarButtonItem = actions.isEmpty ? nil : UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: actions)
        )
    }

    private func makeAccessoryView(for row: Row) -> UIView? {
        guard let onDownload else { return nil }
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        button.tintColor = .secondaryLabel
        button.showsMenuAsPrimaryAction = true
        button.isEnabled = row.audioReady
        button.menu = UIMenu(children: [
            UIAction(
                title: L10n.string("player.downloadAll"),
                image: UIImage(systemName: "arrow.down.circle")
            ) { _ in
                onDownload(row.zeroBasedIndex)
            }
        ])
        return button
    }

    @objc
    private func doneTapped() {
        dismiss(animated: true)
    }
}
#endif
