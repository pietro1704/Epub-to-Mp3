#if os(iOS)
import UIKit

/// A preview never mounts another chapter. Only the explicit action may navigate,
/// after checking that the originating reader and load are still current.
@MainActor
final class ReaderLinkPresentation {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let settings: AppSettings
    private let persist: () -> Void
    private let showChapter: (Int) -> Void
    private let present: (UIViewController) -> Void
    private let isCurrentBook: () -> Bool

    init(document: ReaderBookDocument, composition: ReaderViewComposition, settings: AppSettings,
         persist: @escaping () -> Void, showChapter: @escaping (Int) -> Void,
         present: @escaping (UIViewController) -> Void, isCurrentBook: @escaping () -> Bool) {
        self.document = document
        self.composition = composition
        self.settings = settings
        self.persist = persist
        self.showChapter = showChapter
        self.present = present
        self.isCurrentBook = isCurrentBook
    }

    /// Return true only for an external URL the system may open.
    func handle(_ url: URL, linkText: String) -> Bool {
        if ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") { return true }
        guard isCurrentBook() else { return false }
        let origin = document.selectedChapter
        let chapters: [EbookFulltext.Chapter]
        let positions: [Int]
        if let fulltext = document.fulltext {
            chapters = fulltext.chapters
            positions = Array(chapters.indices)
        } else if let prepared = document.activePreparedChapter, prepared.chapterOrdinal == origin {
            chapters = [prepared.chapter]
            positions = [origin]
        } else { unavailable(); return false }
        guard let currentPosition = positions.firstIndex(of: origin) else { unavailable(); return false }
        let current = chapters[currentPosition]
        if let target = ReaderLinkResolver.internalTarget(for: url, currentChapter: current, chapters: chapters) {
            let chapter = chapters[target.chapterPosition]
            guard let body = render(target.html, chapter: chapter), body.length > 0 else { unavailable(); return false }
            let generation = document.loadGenerationID
            let sheet = ReaderLinkPreviewController(title: chapter.displayTitle, body: body) { [weak self] in
                guard let self, isCurrentBook(), document.loadGenerationID == generation,
                      document.selectedChapter == origin else { return }
                let offset = composition.scrollView.contentOffset
                document.selectedChapter = positions[target.chapterPosition]
                showChapter(positions[target.chapterPosition])
                composition.view.layoutIfNeeded()
                if target.fragment == nil {
                    composition.scrollView.setContentOffset(.zero, animated: false)
                } else if let range = ReaderAnchorRange.uniqueRange(preview: body.string,
                    in: composition.textView.attributedText?.string ?? ""), composition.textViewport.reveal(range) {
                    // The viewport owns canonical paginated navigation.
                } else {
                    document.selectedChapter = origin
                    showChapter(origin)
                    composition.view.layoutIfNeeded()
                    composition.scrollView.setContentOffset(offset, animated: false)
                    unavailable()
                    return
                }
                persist()
            }
            present(UINavigationController(rootViewController: sheet))
            return false
        }
        if case .footnote(let note) = ReaderLinkResolver.destination(for: url, linkText: linkText,
            currentChapter: current, chapters: chapters) {
            let body = NSAttributedString(string: note.text, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
            let title = L10n.string("reader.footnotes.title") + (note.number.map { " · " + $0 } ?? "")
            let sheet = ReaderLinkPreviewController(title: title, body: body, navigate: nil)
            present(UINavigationController(rootViewController: sheet))
        } else { unavailable() }
        return false
    }

    private func render(_ html: String?, chapter: EbookFulltext.Chapter) -> NSAttributedString? {
        if let html, let rendered = EpubHtmlRenderer.render(html: html, css: chapter.css, settings: settings,
            fontDirectoryURL: document.registeredFontURLs.first?.deletingLastPathComponent(), resources: chapter.resources) {
            return NSAttributedString(rendered)
        }
        let fallback = html.map(EpubHtmlRenderer.plainText(from:)) ?? chapter.text
        guard !fallback.isEmpty else { return nil }
        return NSAttributedString(string: fallback, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label])
    }

    private func unavailable() {
        let alert = UIAlertController(title: L10n.string("reader.link.title"),
            message: L10n.string("reader.link.unavailable"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
        present(alert)
    }
}
#endif
