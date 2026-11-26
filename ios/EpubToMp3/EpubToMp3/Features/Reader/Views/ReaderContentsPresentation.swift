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
        let playingIndex = player.location.playingBookID == document.book.id
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
                          readingIndex: Int?, canSelectChapter: @escaping (Int) -> Bool = { _ in true },
                          onSelect: @escaping (Int) -> Void) -> UINavigationController {
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
            sourceRows: rows, downloadBookID: downloadEnabled ? book.id : nil,
            canSelectChapter: canSelectChapter)
        downloads.onBusyChange = { [weak controller] busy in
            controller?.navigationItem.prompt = busy ? L10n.string("toc.audioPreparing") : nil
        }
        downloads.onError = { [weak controller] title, message in
            guard let controller, controller.viewIfLoaded?.window != nil else { return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.string("player.close"), style: .default))
            controller.present(alert, animated: true)
        }
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
#endif
