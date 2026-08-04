#if os(iOS)
import UIKit

/// Keeps NotificationCenter tokens outside the view controller's MainActor
/// isolation so cleanup remains valid even when ARC releases the controller
/// from a nonisolated context.
private final class TocNotificationObserverBag {
    private var observers: [NSObjectProtocol] = []

    func append(_ observer: NSObjectProtocol) {
        observers.append(observer)
    }

    deinit {
        observers.forEach { observer in
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor
final class TocScreenController: UITableViewController {
    private struct Row {
        let title: String
        let zeroBasedIndex: Int
        let charCount: Int?
        let isCurrent: Bool
        let audioReady: Bool
        let downloaded: Bool
        let artifactState: LocalAudioArtifactStore.ArtifactState?
        let schedulerState: LocalAudioConversionScheduler.WorkState?
    }

    private var fulltext: EbookFulltext?
    private var snapshot: JobSnapshot
    private var currentChapterIndex: Int
    private var readingChapterIndex: Int?
    private var onJump: (Int) -> Void
    private var onDownload: ((Int) -> Void)?
    private var onRemoveDownload: ((Int) -> Void)?
    private var onDownloadAll: (() -> Void)?
    private var onCancelDownloads: (() -> Void)?
    private var onClearDownloads: (() -> Void)?
    private var onRetryFailed: (() -> Void)?
    private var onExport: (() -> Void)?
    private var locallyDownloaded: Set<Int> = []
    private var localArtifactStates: [Int: LocalAudioArtifactStore.ArtifactState] = [:]
    private let notificationObservers = TocNotificationObserverBag()

    init(
        fulltext: EbookFulltext?,
        snapshot: JobSnapshot,
        currentChapterIndex: Int,
        readingChapterIndex: Int?,
        onJump: @escaping (Int) -> Void,
        onDownload: ((Int) -> Void)?,
        onRemoveDownload: ((Int) -> Void)? = nil,
        onDownloadAll: (() -> Void)?,
        onCancelDownloads: (() -> Void)?,
        onClearDownloads: (() -> Void)?,
        onRetryFailed: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil
    ) {
        self.fulltext = fulltext
        self.snapshot = snapshot
        self.currentChapterIndex = currentChapterIndex
        self.readingChapterIndex = readingChapterIndex
        self.onJump = onJump
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onDownloadAll = onDownloadAll
        self.onCancelDownloads = onCancelDownloads
        self.onClearDownloads = onClearDownloads
        self.onRetryFailed = onRetryFailed
        self.onExport = onExport
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
        observeLocalAudioArtifacts()
        observeConversionScheduler()
        refreshDownloaded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshDownloaded()
    }

    func update(
        fulltext: EbookFulltext?,
        snapshot: JobSnapshot,
        currentChapterIndex: Int,
        readingChapterIndex: Int?,
        onJump: @escaping (Int) -> Void,
        onDownload: ((Int) -> Void)?,
        onRemoveDownload: ((Int) -> Void)? = nil,
        onDownloadAll: (() -> Void)?,
        onCancelDownloads: (() -> Void)?,
        onClearDownloads: (() -> Void)?,
        onRetryFailed: (() -> Void)? = nil,
        onExport: (() -> Void)? = nil
    ) {
        self.fulltext = fulltext
        self.snapshot = snapshot
        self.currentChapterIndex = currentChapterIndex
        self.readingChapterIndex = readingChapterIndex
        self.onJump = onJump
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.onDownloadAll = onDownloadAll
        self.onCancelDownloads = onCancelDownloads
        self.onClearDownloads = onClearDownloads
        self.onRetryFailed = onRetryFailed
        self.onExport = onExport
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
        } else if let status = artifactStatusText(for: row.artifactState) {
            secondary.append(status)
        } else if Self.usesSchedulerStatus(
            artifactState: row.artifactState,
            schedulerState: row.schedulerState
        ),
                  let status = schedulerStatusText(for: row.schedulerState) {
            secondary.append(status)
        } else if !row.audioReady {
            secondary.append(L10n.string("toc.textOnly"))
        }
        content.secondaryText = secondary.joined(separator: " · ")
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = row.isCurrent ? .checkmark : .none
        cell.accessoryView = makeAccessoryView(for: row)
        cell.accessibilityLabel = row.title
        cell.accessibilityValue = row.downloaded
            ? L10n.string("toc.downloaded")
            : (artifactStatusText(for: row.artifactState)
                ?? (Self.usesSchedulerStatus(
                    artifactState: row.artifactState,
                    schedulerState: row.schedulerState
                ) ? schedulerStatusText(for: row.schedulerState) : nil)
                ?? (row.audioReady ? L10n.string("player.downloadChapter") : L10n.string("toc.textOnly")))
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
        let usesEmbeddedAudio = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) != nil
        let schedulerState = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId).flatMap {
            LocalAudioConversionScheduler.shared.state(for: $0)
        }
        if let fulltext, !fulltext.chapters.isEmpty {
            return fulltext.chapters.map { chapter in
                let zeroBased = chapter.index - 1
                return Row(
                    title: chapter.tocTitle ?? L10n.string("toc.untitledChapter"),
                    zeroBasedIndex: zeroBased,
                    charCount: chapter.charCount,
                    isCurrent: isCurrent(zeroBasedIndex: zeroBased),
                    audioReady: usesEmbeddedAudio || snapshot.playableChapters.contains {
                        $0.index == zeroBased && $0.downloadUrl != nil
                    },
                    downloaded: locallyDownloaded.contains(zeroBased),
                    artifactState: localArtifactStates[zeroBased],
                    schedulerState: schedulerState
                )
            }
        }
        return snapshot.playableChapters.map { chapter in
            Row(
                title: chapter.displayTitle,
                zeroBasedIndex: chapter.index,
                charCount: chapter.chars,
                isCurrent: isCurrent(zeroBasedIndex: chapter.index),
                audioReady: usesEmbeddedAudio || chapter.downloadUrl != nil,
                downloaded: locallyDownloaded.contains(chapter.index),
                artifactState: localArtifactStates[chapter.index],
                schedulerState: schedulerState
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

    /// A chapter-specific state always wins. A pending manifest entry has no
    /// active conversion of its own, so it may surface the book's FIFO or
    /// Wi-Fi wait state without falsely presenting every pending row as the
    /// chapter currently being generated.
    static func usesSchedulerStatus(
        artifactState: LocalAudioArtifactStore.ArtifactState?,
        schedulerState: LocalAudioConversionScheduler.WorkState?
    ) -> Bool {
        switch artifactState {
        case .none:
            return schedulerState != nil
        case .pending:
            return schedulerState == .queued || schedulerState == .waitingForWiFi
        case .generating, .waitingForWiFi, .available, .failed:
            return false
        }
    }

    private func refreshDownloaded() {
        // `Task.detached` does not inherit the enclosing `@MainActor`
        // isolation, so `snapshot` (a MainActor-isolated property) must be
        // captured into a plain local before crossing into the detached
        // closure — referencing `self.snapshot` directly from inside it is
        // both a capture-semantics error and an actor-isolation violation.
        let jobID = snapshot.jobId
        let embeddedBookID = EmbeddedConversionCoordinator.embeddedBookID(from: jobID)
        Task { [weak self] in
            let downloaded: Set<Int>
            let states: [Int: LocalAudioArtifactStore.ArtifactState]
            if let embeddedBookID {
                let manifest = try? await LocalAudioArtifactStore.shared.manifest(bookID: embeddedBookID)
                downloaded = Set(manifest?.chapters.compactMap { artifact in
                    guard artifact.retention == .downloaded, artifact.state == .available else { return nil }
                    return artifact.index
                } ?? [])
                states = Dictionary(
                    uniqueKeysWithValues: (manifest?.chapters ?? []).map { ($0.index, $0.state) }
                )
            } else {
                downloaded = await Task.detached(priority: .utility) {
                    DownloadManager.locallyDownloadedIndices(for: jobID)
                }.value
                states = [:]
            }
            guard let self else { return }
            self.locallyDownloaded = downloaded
            self.localArtifactStates = states
            self.configureMoreMenu()
            self.tableView.reloadData()
        }
    }

    private func observeLocalAudioArtifacts() {
        guard let embeddedBookID = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: LocalAudioArtifactStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let changedBookID = notification.userInfo?["bookID"] as? String,
               changedBookID != embeddedBookID {
                return
            }
            Task { @MainActor [weak self] in
                self?.refreshDownloaded()
            }
        }
        notificationObservers.append(observer)
    }

    private func observeConversionScheduler() {
        guard let embeddedBookID = EmbeddedConversionCoordinator.embeddedBookID(from: snapshot.jobId) else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: LocalAudioConversionScheduler.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard notification.userInfo?["bookID"] as? String == embeddedBookID else { return }
            Task { @MainActor [weak self] in
                self?.refreshDownloaded()
            }
        }
        notificationObservers.append(observer)
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
                UIAction(title: L10n.string("chapterList.removeDownloads"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmRemovingAllDownloads(action)
                }
            },
            localArtifactStates.values.contains(.failed) ? onRetryFailed.map { action in
                UIAction(title: L10n.string("toc.retryFailed"), image: UIImage(systemName: "arrow.clockwise")) { _ in
                    action()
                }
            } : nil,
            onExport.map { action in
                UIAction(title: L10n.string("player.exportAudio"), image: UIImage(systemName: "square.and.arrow.up")) { _ in
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
        let usesSchedulerStatus = Self.usesSchedulerStatus(
            artifactState: row.artifactState,
            schedulerState: row.schedulerState
        )
        let isWorking = row.artifactState == .generating
            || row.artifactState == .waitingForWiFi
            || (usesSchedulerStatus && row.schedulerState == .waitingForWiFi)
        let imageName: String
        if row.downloaded {
            imageName = "checkmark.circle.fill"
        } else if row.artifactState == .generating {
            imageName = "arrow.triangle.2.circlepath.circle"
        } else if row.artifactState == .waitingForWiFi {
            imageName = "wifi"
        } else if usesSchedulerStatus, row.schedulerState == .waitingForWiFi {
            imageName = "wifi"
        } else if usesSchedulerStatus, row.schedulerState == .queued {
            imageName = "clock"
        } else if usesSchedulerStatus, row.schedulerState == .generating {
            imageName = "arrow.triangle.2.circlepath.circle"
        } else if row.artifactState == .failed {
            imageName = "arrow.clockwise.circle"
        } else {
            imageName = "arrow.down.circle"
        }
        button.setImage(UIImage(systemName: imageName), for: .normal)
        button.tintColor = .secondaryLabel
        button.isEnabled = !isWorking && (row.downloaded ? onRemoveDownload != nil : row.audioReady)
        button.accessibilityLabel = row.downloaded
            ? L10n.string("toc.removeDownload")
            : L10n.string("player.downloadChapter")
        button.accessibilityIdentifier = "reader.toc.download.\(row.zeroBasedIndex)"
        button.accessibilityValue = row.downloaded ? L10n.string("toc.downloaded") : nil
        // UITableViewCell owns the frame of its accessoryView. Constraints on
        // the button make it escape the trailing accessory slot on iOS 18.
        button.frame.size = CGSize(width: 44, height: 44)
        if isWorking {
            button.accessibilityValue = artifactStatusText(for: row.artifactState)
                ?? (usesSchedulerStatus ? schedulerStatusText(for: row.schedulerState) : nil)
        } else if row.downloaded, let onRemoveDownload {
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: [
                UIAction(
                    title: L10n.string("toc.removeDownload"),
                    image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.confirmRemovingDownload(
                        chapterIndex: row.zeroBasedIndex,
                        title: row.title,
                        action: onRemoveDownload
                    )
                }
            ])
        } else {
            button.addAction(UIAction { _ in
                onDownload(row.zeroBasedIndex)
            }, for: .touchUpInside)
        }
        return button
    }

    private func confirmRemovingDownload(
        chapterIndex: Int,
        title: String,
        action: @escaping (Int) -> Void
    ) {
        let alert = UIAlertController(
            title: L10n.string("toc.removeDownload"),
            message: L10n.string("toc.removeDownloadMessage", title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.remove"), style: .destructive) { _ in
            action(chapterIndex)
        })
        present(alert, animated: true)
    }

    private func confirmRemovingAllDownloads(_ action: @escaping () -> Void) {
        let alert = UIAlertController(
            title: L10n.string("chapterList.removeDownloads"),
            message: L10n.string("chapterList.removeDownloadsMessage"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.remove"), style: .destructive) { _ in
            action()
        })
        present(alert, animated: true)
    }

    private func artifactStatusText(for state: LocalAudioArtifactStore.ArtifactState?) -> String? {
        switch state {
        case .generating:
            return L10n.string("toc.audioPreparing")
        case .waitingForWiFi:
            return L10n.string("toc.waitingForWiFi")
        case .failed:
            return L10n.string("player.downloadFailed")
        case .pending, .available, .none:
            return nil
        }
    }

    private func schedulerStatusText(for state: LocalAudioConversionScheduler.WorkState?) -> String? {
        switch state {
        case .generating:
            return L10n.string("toc.audioPreparing")
        case .waitingForWiFi:
            return L10n.string("toc.waitingForWiFi")
        case .failed:
            return L10n.string("player.downloadFailed")
        case .queued:
            return L10n.string("toc.audioQueued")
        case .finished, .none:
            return nil
        }
    }

    @objc
    private func doneTapped() {
        dismiss(animated: true)
    }
}
#endif
