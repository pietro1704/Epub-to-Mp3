#if os(iOS)
import UIKit

@MainActor
final class ReaderContentsPresentation {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let settings: AppSettings
    private let player: AudioPlayer
    private let readingPosition: ReaderReadingPosition
    private let textPresentation: ReaderTextPresentation
    private let present: (UIViewController) -> Void

    init(document: ReaderBookDocument, composition: ReaderViewComposition, settings: AppSettings,
         player: AudioPlayer, readingPosition: ReaderReadingPosition, textPresentation: ReaderTextPresentation,
         present: @escaping (UIViewController) -> Void) {
        self.document = document
        self.composition = composition
        self.settings = settings
        self.player = player
        self.readingPosition = readingPosition
        self.textPresentation = textPresentation
        self.present = present
    }

    private var tocRows: [ReaderTocRow] {
        guard let fulltext = document.fulltext else { return [] }
        return ReaderTocFlattener.rows(toc: fulltext.toc, chapters: fulltext.chapters)
    }

    /// TOC is a floating modal sheet — never inline in the reader's own
    /// layout — so a book always opens directly into its content and the
    /// chapter list never pushes or overlays the reading column.
    func presentTOC() {
        if let snapshot = player.snapshot {
            let controller = TocScreenController(
                fulltext: document.fulltext ?? EbookFulltext(
                    jobId: snapshot.jobId,
                    bookTitle: nil,
                    bookAuthor: nil,
                    chapters: [],
                    toc: nil
                ),
                snapshot: snapshot,
                currentChapterIndex: player.currentChapterIndex,
                readingChapterIndex: document.selectedChapter,
                onJump: { [weak self] chapterIndex in
                    self?.document.selectedChapter = chapterIndex
                    self?.textPresentation.showChapter(chapterIndex)
                    self?.composition.scrollView.setContentOffset(.zero, animated: false)
                },
                onDownload: { [weak self] chapterIndex in
                    guard let self else { return }
                    self.requestAudioDownload(snapshot: snapshot, chapterIndex: chapterIndex)
                },
                onRemoveDownload: { chapterIndex in
                    AudiobookDownloadStorage.deleteChapter(jobId: snapshot.jobId, chapterIndex: chapterIndex)
                },
                onDownloadAll: { [weak self] in
                    guard let self else { return }
                    self.requestAudioDownload(snapshot: snapshot, chapterIndex: nil)
                },
                onCancelDownloads: true
                    ? { Task { await AudiobookDownloads.shared.cancel(jobId: snapshot.jobId) } }
                    : nil,
                onClearDownloads: {
                    Task { await AudiobookDownloads.shared.clearDownloadedBook(jobId: snapshot.jobId) }
                },
                onRetryFailed: nil,
                onExport: nil
            )
            let nav = UINavigationController(rootViewController: controller)
            configureTOCSheetPresentation(nav)
            present(nav)
            return
        }
        let sheet = ReaderContentsSheet(rows: tocRows, initialChapterIndex: document.selectedChapter) { [weak self] chapterIndex in
            guard let self else { return }
            self.readingPosition.persistReadingProgress()
            self.document.selectedChapter = chapterIndex
            self.textPresentation.showChapter(chapterIndex)
            self.composition.scrollView.setContentOffset(.zero, animated: false)
        }
        let nav = UINavigationController(rootViewController: sheet)
        configureTOCSheetPresentation(nav)
        present(nav)
    }

    /// Keeps the chapter index as a native large sheet: it reaches the top
    /// safe area while preserving the system grabber and swipe-to-dismiss
    /// gesture rather than imitating either with custom layout.
    private func configureTOCSheetPresentation(_ navigationController: UINavigationController) {
        navigationController.modalPresentationStyle = .pageSheet
        guard let sheet = navigationController.sheetPresentationController else { return }
        sheet.detents = [.large()]
        sheet.selectedDetentIdentifier = .large
        sheet.prefersGrabberVisible = true
    }

    private func requestAudioDownload(snapshot: JobSnapshot, chapterIndex: Int?) {
        Task {
            if let chapterIndex {
                await AudiobookDownloads.shared.enqueueSelected(snapshot: snapshot, epubZeroBasedIndices: [chapterIndex], baseURL: settings.resolvedBaseURL)
            } else {
                await AudiobookDownloads.shared.enqueueAll(snapshot: snapshot, baseURL: settings.resolvedBaseURL)
            }
        }
    }

}
#endif
