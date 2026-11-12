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
    guard let attributed = textView.attributedText else { return }
    let selection = textView.selectedRange
    let offset = composition.scrollView.contentOffset
    let highlights = bookmarkStore.bookmarks(for: document.book.id, chapterIndex: chapterIndex)
    textView.textStorage.setAttributedString(ReaderSavedHighlights.repaint(attributed, highlights: highlights))
    textView.selectedRange = selection
    composition.scrollView.setContentOffset(offset, animated: false)
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

var onPlayFromHere: ((Int, Double) -> Void)?

@available(iOS 16.0, *)
func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
              suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard valid(range) else { return UIMenu(children: suggestedActions) }
    let chapter = document.selectedChapter
    let bookID = document.book.id
    let target = ReaderSavedHighlights.target(at: range, highlights:
        bookmarkStore.bookmarks(for: bookID, chapterIndex: chapter), in: textView.attributedText)
    let playbackRange = target.flatMap { ReaderSavedHighlights.range(for: $0, in: textView.attributedText) } ?? range
    let play = UIAction(title: L10n.string("reader.action.playFromHere"), image: UIImage(systemName: "play")) { [weak self] _ in
        guard let self, self.isCurrent(bookID: bookID, chapter: chapter) else { return }
        self.play(from: playbackRange)
    }
    let change = UIAction(title: L10n.string(target == nil ? "reader.action.highlight" : "reader.action.removeHighlight"),
                          image: UIImage(systemName: target == nil ? "highlighter" : "trash")) { [weak self] _ in
        guard let self, self.isCurrent(bookID: bookID, chapter: chapter) else { return }
        if let target { self.removeHighlight(target) }
        else { self.addBookmark(range: range, selectedText: (textView.text as NSString).substring(with: range), note: nil) }
    }
    let note = UIAction(title: L10n.string("reader.action.addNote")) { [weak self] _ in
        guard let self, self.isCurrent(bookID: bookID, chapter: chapter) else { return }
        self.promptForNote(range: range, selectedText: (textView.text as NSString).substring(with: range))
    }
    let more = UIMenu(title: L10n.string("reader.selection.more"), image: UIImage(systemName: "ellipsis"), children: [change, note])
    return UIMenu(children: [play, more] + suggestedActions)
}

func installLegacySelectionActions() {
    (textView as? ReaderSelectionTextView)?.onLegacyCommand = { [weak self] more, range in
        guard let self, self.valid(range) else { return }
        if !more { self.play(from: range); return }
        let chapter = self.document.selectedChapter
        let bookID = self.document.book.id
        let target = ReaderSavedHighlights.target(at: range, highlights:
            self.bookmarkStore.bookmarks(for: bookID, chapterIndex: chapter), in: self.textView.attributedText)
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: L10n.string(target == nil ? "reader.action.highlight" : "reader.action.removeHighlight"),
            style: target == nil ? .default : .destructive) { [weak self] _ in
            guard let self, self.isCurrent(bookID: bookID, chapter: chapter) else { return }
            if let target { self.removeHighlight(target) }
            else { self.addBookmark(range: range, selectedText: (self.textView.text as NSString).substring(with: range), note: nil) }
        })
        alert.addAction(UIAlertAction(title: L10n.string("reader.action.addNote"), style: .default) { [weak self] _ in
            guard let self, self.isCurrent(bookID: bookID, chapter: chapter) else { return }
            self.promptForNote(range: range, selectedText: (self.textView.text as NSString).substring(with: range))
        })
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.popoverPresentationController?.sourceView = self.textView
        alert.popoverPresentationController?.sourceRect = self.textView.bounds
        self.present(alert)
    }
}

private func valid(_ range: NSRange) -> Bool {
    range.location != NSNotFound && range.location >= 0 && range.length > 0
        && range.location < textView.textStorage.length && range.length <= textView.textStorage.length - range.location
}
private func isCurrent(bookID: String, chapter: Int) -> Bool {
    isCurrentBook() && document.book.id == bookID && document.selectedChapter == chapter
}
private func play(from range: NSRange) {
    guard valid(range),
          let source = document.activePreparedChapter?.chapter ?? document.fulltext?.chapters[safe: document.selectedChapter],
          let ratio = ReaderSavedHighlights.playbackRatio(selection: range, rendered: textView.text, source: source.text) else { return }
    onPlayFromHere?(source.zeroBasedEpubIndex, ratio)
}
private func removeHighlight(_ bookmark: Bookmark) {
    bookmarkStore.remove(id: bookmark.id)
    repaintSavedHighlights(chapterIndex: document.selectedChapter)
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
