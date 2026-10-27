#if os(iOS)
import UIKit

/// Selection, links, footnotes and search share the actual displayed text and
/// source chapter identity; they never derive ranges by parsing Swift source.
@MainActor
final class ReaderAnnotationsPresentation: NSObject, UITextViewDelegate {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let settings: AppSettings
    private let bookmarkStore: BookmarkStore
    private let persistProgress: () -> Void
    private let showChapter: (Int) -> Void
    private let present: (UIViewController) -> Void
    private let isCurrentBook: () -> Bool
    private lazy var search = ReaderSearchPresentation(document: document, composition: composition,
        persist: persistProgress, showChapter: showChapter, present: present, isCurrentBook: isCurrentBook)
    private lazy var links = ReaderLinkPresentation(document: document, composition: composition, settings: settings,
        persist: persistProgress, showChapter: showChapter, present: present, isCurrentBook: isCurrentBook)
    private var textView: UITextView { composition.textView }

    init(document: ReaderBookDocument, composition: ReaderViewComposition, bookmarkStore: BookmarkStore, settings: AppSettings,
         persistProgress: @escaping () -> Void, showChapter: @escaping (Int) -> Void,
         present: @escaping (UIViewController) -> Void, isCurrentBook: @escaping () -> Bool = { true }) {
        self.document = document
        self.composition = composition
        self.bookmarkStore = bookmarkStore
        self.settings = settings
        self.persistProgress = persistProgress
        self.showChapter = showChapter
        self.present = present
        self.isCurrentBook = isCurrentBook
        super.init()
    }

    // MARK: - Selection → bookmark/highlight/note

    /// Repaints every saved highlight for this chapter as a background
    /// tint. Offsets are resolved against the text actually on screen
    /// right now (`ReaderTextHighlight`), not the Python `chapter.text`
    /// pipeline — see the "Known limitations" note on
    /// `EpubHtmlRenderer.render`.
    func repaintSavedHighlights(chapterIndex: Int) {
        let highlights = bookmarkStore.bookmarks(for: document.book.id, chapterIndex: chapterIndex).filter { $0.isHighlight }
        guard !highlights.isEmpty, let attributed = textView.attributedText, attributed.length > 0 else { return }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        for bookmark in highlights {
            let span = SentenceSpan(
                id: bookmark.id.uuidString, text: bookmark.selectedText,
                startChar: bookmark.startChar, endChar: bookmark.endChar
            )
            guard let range = ReaderTextHighlight.range(for: span, in: mutable) else { continue }
            mutable.addAttribute(.backgroundColor, value: bookmark.color.platformColor, range: range)
        }
        textView.attributedText = mutable
    }

    func textView(
        _ textView: UITextView,
        shouldInteractWith url: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        guard characterRange.location != NSNotFound, characterRange.location >= 0, characterRange.length > 0,
              characterRange.location <= textView.attributedText.length,
              characterRange.length <= textView.attributedText.length - characterRange.location else { return false }
        let linkedText = (textView.attributedText.string as NSString).substring(with: characterRange)
        cancelSearch()
        return links.handle(url, linkText: linkedText)
    }

    @available(iOS 16.0, *)
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard range.length > 0 else { return UIMenu(children: suggestedActions) }
        let selectedText = (textView.text as NSString).substring(with: range)
        let highlight = UIAction(title: L10n.string("reader.action.highlight")) { [weak self] _ in
            self?.addBookmark(range: range, selectedText: selectedText, note: nil)
        }
        let note = UIAction(title: L10n.string("reader.action.addNote")) { [weak self] _ in
            self?.promptForNote(range: range, selectedText: selectedText)
        }
        let bookmarkMenu = UIMenu(title: "", options: .displayInline, children: [highlight, note])
        return UIMenu(children: [bookmarkMenu] + suggestedActions)
    }

    private func promptForNote(range: NSRange, selectedText: String) {
        let alert = UIAlertController(
            title: L10n.string("reader.action.addNote"), message: selectedText, preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = L10n.string("reader.note.placeholder") }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.save"), style: .default) { [weak self, weak alert] _ in
            let note = alert?.textFields?.first?.text
            self?.addBookmark(range: range, selectedText: selectedText, note: note)
        })
        present(alert)
    }

    // MARK: - Footnotes

    func showFootnotes() {
        guard let footnotes = document.fulltext?.chapters[safe: document.selectedChapter]?.footnotes, !footnotes.isEmpty else {
            let alert = UIAlertController(
                title: L10n.string("reader.footnotes.title"),
                message: L10n.string("reader.footnotes.empty"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.string("common.ok"), style: .default))
            present(alert)
            return
        }
        let sheet = ReaderFootnotesSheet(footnotes: footnotes)
        present(UINavigationController(rootViewController: sheet))
    }

    // MARK: - Book search

    func promptSearch() { search.promptSearch() }
    func performSearch(query: String) { search.performSearch(query: query) }
    func waitForSearchCompletion() async { await search.waitForCompletion() }
    func cancelSearch() { search.cancel() }

    private func addBookmark(range: NSRange, selectedText: String, note: String?) {
        bookmarkStore.addBookmark(
            bookId: document.book.id,
            chapterIndex: document.selectedChapter,
            chapterTitle: document.fulltext?.chapters[safe: document.selectedChapter]?.displayTitle ?? "",
            startChar: range.location,
            endChar: range.location + range.length,
            selectedText: selectedText,
            note: note,
            color: .yellow
        )
        repaintSavedHighlights(chapterIndex: document.selectedChapter)
    }

}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
