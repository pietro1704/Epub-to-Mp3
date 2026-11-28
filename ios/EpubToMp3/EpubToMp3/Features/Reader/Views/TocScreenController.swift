#if os(iOS)
import UIKit

@MainActor
final class TocScreenController: UITableViewController {
    private typealias Row = TocAudioAvailabilityPresentation.Row

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
    private var hasScrolledToInitialFocus = false
    private var downloadProgressTask: Task<Void, Never>?
    private var downloadRefreshTask: Task<Void, Never>?
    private var isVisible = false
    private var sourceRows: [ReaderTocRow]?
    var renaming: ContentsRenaming?
    private let downloadBookID: String?
    private let canSelectChapter: (Int) -> Bool

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
        onExport: (() -> Void)? = nil,
        sourceRows: [ReaderTocRow]? = nil,
        downloadBookID: String? = nil,
        canSelectChapter: @escaping (Int) -> Bool = { _ in true }
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
        self.sourceRows = sourceRows
        self.downloadBookID = downloadBookID
        self.canSelectChapter = canSelectChapter
        super.init(style: .plain)
        title = L10n.string("player.chapters")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "reader.toc"
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
        isVisible = true
        observeDownloadProgress()
        view.layoutIfNeeded()
        scrollToInitialFocusIfNeeded()
        refreshDownloaded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        downloadProgressTask?.cancel()
        downloadProgressTask = nil
    }

    deinit {
        downloadProgressTask?.cancel()
        downloadRefreshTask?.cancel()
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
        let previousJobID = self.snapshot.jobId
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
        if isVisible, previousJobID != snapshot.jobId {
            observeDownloadProgress()
            refreshDownloaded()
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let row = rows[indexPath.row]
        let isFocused = TocChapterPresentation.initialFocusChapterIndex(
            currentChapterIndex: currentChapterIndex,
            readingChapterIndex: readingChapterIndex
        ) == row.zeroBasedIndex
        let removeAction: ((Int, String) -> Void)?
        if let action = onRemoveDownload {
            removeAction = { [weak self] index, title in
                self?.confirmRemovingDownload(chapterIndex: index, title: title, action: action)
            }
        } else {
            removeAction = nil
        }
        TocAudioAvailabilityPresentation.configure(
            cell, row: row, isFocused: isFocused, tintColor: view.tintColor,
            isSelectable: isSelectable(row.zeroBasedIndex),
            onDownload: row.zeroBasedIndex >= 0 ? onDownload : nil, onRemoveDownload: removeAction
        )
        return cell
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        selectionTarget(at: indexPath) == nil ? nil : indexPath
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let chapter = selectionTarget(at: indexPath) else { return }
        onJump(chapter)
        dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        let actions = renameActions(at: indexPath.row)
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in UIMenu(children: actions) })
    }

    func renameActions(at position: Int) -> [UIAction] {
        (renaming?.actions(position) ?? []).map { action in
            UIAction(title: action.title,
                     image: UIImage(systemName: action.kind == .rename ? "pencil" : "arrow.uturn.backward")) { [weak self] _ in
                switch action.kind {
                case .rename: self?.askForName(at: position)
                case .restore: self?.applyName(nil, at: position)
                }
            }
        }
    }

    private func askForName(at position: Int) {
        guard let current = sourceRows?[position].title else { return }
        let alert = UIAlertController(title: L10n.string("toc.rename"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = current
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
            field.accessibilityIdentifier = "reader.toc.rename.field"
        }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("toc.renameSave"), style: .default) { [weak self, weak alert] _ in
            // A blank name restores the automatic one; an unchanged one is not an override.
            guard let name = alert?.textFields?.first?.text, name != current else { return }
            self?.applyName(name, at: position)
        })
        present(alert, animated: true)
    }

    private func applyName(_ name: String?, at position: Int) {
        do {
            guard let rows = try renaming?.apply(position, name) else { return }
            sourceRows = rows
            tableView.reloadData()
        } catch {
            let alert = UIAlertController(title: L10n.string("toc.rename"), message: L10n.string("toc.renameFailed"),
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("player.close"), style: .default))
            present(alert, animated: true)
        }
    }

    private func selectionTarget(at indexPath: IndexPath) -> Int? {
        let rows = rows
        guard rows.indices.contains(indexPath.row) else { return nil }
        let chapter = rows[indexPath.row].zeroBasedIndex
        return isSelectable(chapter) ? chapter : nil
    }

    private func isSelectable(_ chapter: Int) -> Bool {
        chapter >= 0 && canSelectChapter(chapter)
    }

    private var rows: [Row] {
        if let sourceRows {
            return sourceRows.map { row in
                let index = row.chapterIndex ?? -1
                return Row(title: row.title, zeroBasedIndex: index,
                           charCount: nil, isCurrent: index >= 0 && isCurrent(zeroBasedIndex: index),
                           audioReady: downloadBookID != nil && index >= 0,
                           downloaded: locallyDownloaded.contains(index),
                           artifactState: localArtifactStates[index], schedulerState: nil,
                           level: row.level)
            }
        }
        let usesEmbeddedAudio = false
        let schedulerState: LocalAudioConversionScheduler.WorkState? = nil
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

    private func scrollToInitialFocusIfNeeded() {
        guard !hasScrolledToInitialFocus,
              let chapterIndex = TocChapterPresentation.initialFocusChapterIndex(
                  currentChapterIndex: currentChapterIndex,
                  readingChapterIndex: readingChapterIndex
              ),
              let rowIndex = rows.firstIndex(where: { $0.zeroBasedIndex == chapterIndex }) else {
            return
        }
        hasScrolledToInitialFocus = true
        tableView.layoutIfNeeded()
        tableView.scrollToRow(
            at: IndexPath(row: rowIndex, section: 0),
            at: .middle,
            animated: false
        )
    }

    private func refreshDownloaded() {
        let snapshot = snapshot
        downloadRefreshTask?.cancel()
        downloadRefreshTask = Task { [weak self] in
            let downloaded: Set<Int>
            if let bookID = self?.downloadBookID {
                downloaded = (try? await LocalAudioArtifactStore.shared.downloadedChapterIndicesInFiles(bookID: bookID)) ?? []
            } else {
                downloaded = await AudiobookDownloads.shared.downloadedIndices(for: snapshot)
            }
            guard !Task.isCancelled, let self, self.snapshot.jobId == snapshot.jobId else { return }
            self.locallyDownloaded = downloaded
            self.localArtifactStates = [:]
            self.configureMoreMenu()
            if let visibleRows = self.tableView.indexPathsForVisibleRows, !visibleRows.isEmpty {
                self.tableView.reconfigureRows(at: visibleRows)
            }
        }
    }

    /// Kept audio also changes outside this screen's own Download requests:
    /// a removal here, the Settings list, or the launch migration.
    private func observeLocalAudioArtifacts() {
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: LocalAudioArtifactStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDownloaded() }
        })
    }

    private func observeDownloadProgress() {
        downloadProgressTask?.cancel()
        let jobID = snapshot.jobId
        downloadProgressTask = Task { [weak self] in
            let stream = await AudiobookDownloads.shared.watchProgress(jobId: jobID)
            for await progress in stream {
                guard !Task.isCancelled, let self, self.snapshot.jobId == jobID else { return }
                switch progress.state {
                case .completed, .failed, .cancelled:
                    self.refreshDownloaded()
                case .queued, .downloading, .paused:
                    break
                }
            }
        }
    }

    private func observeConversionScheduler() {
        return
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

    @objc
    private func doneTapped() {
        dismiss(animated: true)
    }
}
#endif
