#if os(iOS)
import UIKit

@MainActor
final class ReaderContentsPresentation {
    /// The user picked a chapter in the contents sheet (READER-FOLLOW-NARRATION: a manual move).
    var onUserJump: (() -> Void)?
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let library: LibraryStore
    private let settings: AppSettings
    private let player: AudioPlayer
    private let readingPosition: ReaderReadingPosition
    private let present: (UIViewController) -> Void

    init(document: ReaderBookDocument, composition: ReaderViewComposition, library: LibraryStore, settings: AppSettings,
         player: AudioPlayer, readingPosition: ReaderReadingPosition,
         present: @escaping (UIViewController) -> Void) {
        self.document = document
        self.composition = composition
        self.library = library
        self.settings = settings
        self.player = player
        self.readingPosition = readingPosition
        self.present = present
    }

    func presentTOC(onSelect: ((Int) -> Void)? = nil, presentIn: ((UIViewController) -> Void)? = nil) {
        let fulltext = document.fulltext
        let select: (Int) -> Void
        let rows: [ReaderTocRow]
        if let pdf = composition.contentSurface.pdfPresentation {
            rows = pdf.audioMap?.chapters.enumerated().map {
                ReaderTocRow(title: $0.element.name, level: 0, chapterIndex: $0.offset)
            } ?? []
            select = onSelect ?? { [weak pdf] chapter in pdf?.goToChapter(chapter) }
        } else {
            if let fulltext {
                rows = Self.sourceRows(document.tocRows, fulltext: fulltext)
            } else {
                rows = (document.activePreparedChapter?.catalogChapters ?? []).map { chapter in
                    ReaderTocRow(title: chapter.name ?? L10n.string("player.chapter", chapter.index),
                                 level: 0, chapterIndex: chapter.index > 0 ? chapter.index - 1 : nil)
                }
            }
            let generation = document.loadGenerationID
            let bookID = document.book.id
            select = onSelect ?? { [weak self] sourceChapterIndex in
                guard let self, self.document.book.id == bookID, self.document.loadGenerationID == generation else { return }
                self.onUserJump?()
                self.readingPosition.revealChapterStart(sourceChapterIndex)
            }
        }
        let current = composition.contentSurface.pdfPresentation?.currentAnchor?.chapterIndex
            ?? ReaderPlaybackAnchor.epubIndex(forReaderPosition: document.selectedChapter, in: fulltext?.chapters ?? [])
        let playingIndex = UserDefaults.standard.string(forKey: AudioPlayer.currentBookIDDefaultsKey) == document.book.id
            ? player.playbackClock.audioOutput.position?.chapterIndex : nil
        (presentIn ?? present)(Self.makeSheet(book: document.book, rows: rows, library: library,
            settings: settings, snapshot: player.snapshot, playingIndex: playingIndex,
            readingIndex: current, onSelect: select))
    }

    static func sourceRows(_ rows: [ReaderTocRow], fulltext: EbookFulltext?) -> [ReaderTocRow] {
        guard let chapters = fulltext?.chapters else { return rows }
        return rows.map { row in
            let index = row.chapterIndex.flatMap {
                ReaderPlaybackAnchor.epubIndex(forReaderPosition: $0, in: chapters)
            }
            return ReaderTocRow(title: row.title, level: row.level, chapterIndex: index)
        }
    }

    static func makeSheet(book: BookEntity, rows: [ReaderTocRow], library: LibraryStore,
                          settings: AppSettings, snapshot: JobSnapshot?, playingIndex: Int?,
                          readingIndex: Int?, onSelect: @escaping (Int) -> Void) -> UINavigationController {
        let downloads = ReaderChapterDownloads(book: book, library: library, settings: settings, snapshot: snapshot)
        let downloadEnabled = book.fileType.supportsAudioConversion
        let scopedSnapshot = snapshot.flatMap {
            $0.jobId == "embedded-\(book.id)" ? $0 : nil
        } ?? JobSnapshot(jobId: "embedded-\(book.id)", state: "pending", bookTitle: book.resolvedTitle,
                         bookAuthor: book.author, coverUrl: nil, coverMimeType: nil, engine: nil,
                         voice: nil, language: nil, progressPercent: 0, chaptersTotal: nil,
                         chaptersCompleted: nil, chapterProgress: [], outputs: nil, logUrl: nil,
                         error: nil, lastActivityAt: nil, chapterIndexBase: 0)
        let controller = TocScreenController(fulltext: nil, snapshot: scopedSnapshot,
            currentChapterIndex: playingIndex ?? -1, readingChapterIndex: readingIndex,
            onJump: onSelect, onDownload: downloadEnabled ? { downloads.start([$0]) } : nil,
            onRemoveDownload: downloadEnabled ? { index in Task { await downloads.remove(chapter: index) } } : nil,
            onDownloadAll: downloadEnabled && !rows.isEmpty ? { downloads.start(rows.compactMap(\.chapterIndex)) } : nil,
            onCancelDownloads: downloadEnabled ? { downloads.cancel() } : nil,
            onClearDownloads: downloadEnabled ? { Task { await downloads.remove(chapter: nil) } } : nil,
            sourceRows: rows, downloadBookID: downloadEnabled ? book.id : nil)
        downloads.controller = controller
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        return navigationController
    }
}

/// Keeps explicit chapter downloads separate from listening transport.
@MainActor
final class ReaderChapterDownloads {
    weak var controller: TocScreenController?
    private let book: BookEntity
    private let library: LibraryStore
    private let settings: AppSettings
    private let snapshot: JobSnapshot?
    private var task: Task<Void, Never>?
    private var activeRemovals = 0

    init(book: BookEntity, library: LibraryStore, settings: AppSettings, snapshot: JobSnapshot?) {
        self.book = book
        self.library = library
        self.settings = settings
        self.snapshot = snapshot
    }

    func start(_ indices: [Int]) {
        guard task == nil, activeRemovals == 0 else { return }
        let chapters = Set(indices.filter { $0 >= 0 }).sorted()
        guard !chapters.isEmpty else { return }
        controller?.navigationItem.prompt = L10n.string("toc.audioPreparing")
        task = Task {
            defer {
                task = nil
                controller?.navigationItem.prompt = nil
            }
            do {
                var bookURL: URL?
                var hasSecurityScope = false
                defer { if hasSecurityScope { bookURL?.stopAccessingSecurityScopedResource() } }
                // The book's language decides the narration (cached analysis), like a listening request.
                let options = try await LanguageModelPlayback.conversionOptions(
                    for: book, settings: settings, dependencies: .live(library: library))
                for index in chapters {
                    try Task.checkCancellation()
                    guard library.books.contains(where: { $0.id == book.id }) else { return }
                    if try await keepLocalChapter(index) { continue }
                    guard let position = Int32(exactly: index) else { throw CocoaError(.fileReadCorruptFile) }
                    if bookURL == nil {
                        let file = try await library.openBookFileAsync(id: book.id)
                        bookURL = file
                        hasSecurityScope = file.startAccessingSecurityScopedResource()
                    }
                    guard let bookURL else { throw CocoaError(.fileNoSuchFile) }
                    let control = try RustConversionCoordinator.makePlaybackControl()
                    let result = try await withTaskCancellationHandler {
                        try await RustConversionCoordinator.executeStreaming(
                            bookURL: bookURL, jobID: UUID().uuidString, chapterStart: position,
                            chapterEnd: position, control: control, options: options,
                            onProgress: nil, onChapterCompleted: nil, onAudioChunk: nil)
                    } onCancel: { control.cancel() }
                    try Task.checkCancellation()
                    guard library.books.contains(where: { $0.id == book.id }),
                          let chapter = try result.snapshot().playableChapters.first(where: { $0.index == index }),
                          let source = chapter.downloadUrl.flatMap({ AudiobookChapterTransfer.resolve(path: $0, base: nil) }),
                          source.isFileURL else { throw CocoaError(.fileReadCorruptFile) }
                    try await keep(source, chapter: chapter)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                report(error)
            }
        }
    }

    private func keepLocalChapter(_ index: Int) async throws -> Bool {
        if let local = try await LocalAudioArtifactStore.shared.playableSnapshot(
            bookID: book.id, engine: "local", voice: "auto", language: nil),
           try await keepChapter(in: local, index: index) { return true }
        guard let snapshot, let owner = await RetainedAudioOwner.resolve(snapshot),
              owner.bookID == book.id, owner.indexBase == 0 else { return false }
        return try await keepChapter(in: snapshot, index: index)
    }

    private func keepChapter(in snapshot: JobSnapshot, index: Int) async throws -> Bool {
        guard let chapter = snapshot.playableChapters.first(where: { $0.index == index && ($0.textOffset ?? 0) == 0 }),
              let source = chapter.downloadUrl.flatMap({ AudiobookChapterTransfer.resolve(path: $0, base: nil) }),
              source.isFileURL, FileManager.default.fileExists(atPath: source.path) else { return false }
        try await keep(source, chapter: chapter)
        return true
    }

    private func keep(_ source: URL, chapter: JobSnapshot.Chapter) async throws {
        _ = try await LocalAudioArtifactStore.shared.retainDownload(from: source, request: .init(
            bookID: book.id, bookTitle: book.resolvedTitle, author: book.author,
            chapterIndex: chapter.index, chapterTitle: chapter.displayTitle,
            textOffset: max(0, chapter.textOffset ?? 0)), requireVisibleCopy: true)
    }

    func cancel() { task?.cancel() }

    func remove(chapter: Int?) async {
        activeRemovals += 1
        defer { activeRemovals -= 1 }
        if let task {
            task.cancel()
            await task.value
        }
        if let snapshot, let owner = await RetainedAudioOwner.resolve(snapshot),
           owner.bookID == book.id, owner.indexBase == 0 {
            if let chapter {
                await AudiobookDownloads.shared.removeDownload(snapshot: snapshot, chapterIndex: chapter)
            } else {
                await AudiobookDownloads.shared.clearDownloads(snapshot: snapshot)
            }
        }
        do {
            try await LocalAudioArtifactStore.shared.withdrawDownloadsFromFiles(bookID: book.id, chapterIndex: chapter)
        } catch {
            report(error, context: "Remove download", title: L10n.string("settings.storageRemovalFailedTitle"))
        }
    }

    private func report(_ error: Error, context: String = "Chapter download",
                        title: String = L10n.string("player.downloadFailed")) {
        let message = AppErrorReporter.message(error, context: context)
        guard let controller, controller.viewIfLoaded?.window != nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("player.close"), style: .default))
        controller.present(alert, animated: true)
    }
}
#endif
