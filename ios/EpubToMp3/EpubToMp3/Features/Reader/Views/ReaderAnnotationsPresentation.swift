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
private lazy var highlightEditor = ReaderHighlightEditor(store: bookmarkStore)

/// Captures book, chapter and title now; every later write uses these values.
private func captureSelection(_ range: NSRange) -> ReaderHighlightEditor.Selection? {
    highlightEditor.selection(range: range, in: textView.attributedText, bookID: document.book.id,
        chapterIndex: document.selectedChapter,
        chapterTitle: document.fulltext?.chapters[safe: document.selectedChapter]?.displayTitle ?? "")
}

@available(iOS 16.0, *)
func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
              suggestedActions: [UIMenuElement]) -> UIMenu? {
    guard let selection = captureSelection(range) else { return UIMenu(children: suggestedActions) }
    let playbackRange = highlightEditor.playbackRange(for: selection, in: textView.attributedText)
    let play = UIAction(title: L10n.string("reader.action.playFromHere"), image: UIImage(systemName: "play")) { [weak self] _ in
        guard let self, self.isCurrent(selection) else { return }
        self.play(from: playbackRange)
    }
    let change = UIAction(title: L10n.string(selection.existing == nil ? "reader.action.highlight" : "reader.action.removeHighlight"),
                          image: UIImage(systemName: selection.existing == nil ? "highlighter" : "trash")) { [weak self] _ in
        guard let self, self.isCurrent(selection) else { return }
        self.toggleHighlight(selection)
    }
    let note = UIAction(title: L10n.string("reader.action.addNote")) { [weak self] _ in
        guard let self, self.isCurrent(selection) else { return }
        self.promptForNote(selection)
    }
    let more = UIMenu(title: L10n.string("reader.selection.more"), image: UIImage(systemName: "ellipsis"), children: [change, note] + (selectionLanguageAction(range: range).map { [$0] } ?? []))
    return UIMenu(children: [play, more] + suggestedActions)
}

func installLegacySelectionActions() {
    (textView as? ReaderSelectionTextView)?.onLegacyCommand = { [weak self] more, range in
        guard let self, self.valid(range) else { return }
        if !more { self.play(from: range); return }
        guard let selection = self.captureSelection(range) else { return }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: L10n.string(selection.existing == nil ? "reader.action.highlight" : "reader.action.removeHighlight"),
            style: selection.existing == nil ? .default : .destructive) { [weak self] _ in
            guard let self, self.isCurrent(selection) else { return }
            self.toggleHighlight(selection)
        })
        alert.addAction(UIAlertAction(title: L10n.string("reader.action.addNote"), style: .default) { [weak self] _ in
            guard let self, self.isCurrent(selection) else { return }
            self.promptForNote(selection)
        })
        if let scope = self.selectionLanguageScope(range: range) {
            alert.addAction(UIAlertAction(title: L10n.string("language.passage"), style: .default) { [weak self] _ in
                guard let self, self.isCurrent(selection) else { return }
                self.chooseSelectionLanguage(scope, bookID: selection.bookID, chapter: selection.chapterIndex)
            })
        }
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
private func isCurrent(_ selection: ReaderHighlightEditor.Selection) -> Bool {
    isCurrentBook() && ReaderHighlightEditor.isCurrent(selection, bookID: document.book.id, chapterIndex: document.selectedChapter)
}
private func play(from range: NSRange) {
    guard valid(range),
          let source = document.activePreparedChapter?.chapter ?? document.fulltext?.chapters[safe: document.selectedChapter],
          let ratio = ReaderSavedHighlights.playbackRatio(selection: range, rendered: textView.text, source: source.text) else { return }
    // Play from here leaves the selection mode: no selection stays behind the narration and the edit menu closes.
    textView.selectedRange = NSRange(location: range.location, length: 0)
    textView.resignFirstResponder()
    onPlayFromHere?(source.zeroBasedEpubIndex, ratio)
}
private func toggleHighlight(_ selection: ReaderHighlightEditor.Selection) {
    highlightEditor.toggleHighlight(selection)
    repaintSavedHighlights(chapterIndex: selection.chapterIndex)
}

private func selectionLanguageScope(range: NSRange) -> PassageLanguageCorrection? {
    guard let source = document.activePreparedChapter?.chapter ?? document.fulltext?.chapters[safe: document.selectedChapter] else { return nil }
    return ReaderLanguageSelection.passage(rendered: textView.text, range: range,
        source: source.text, chapterIndex: source.zeroBasedEpubIndex)
}

private func selectionLanguageAction(range: NSRange) -> UIAction? {
    guard let scope = selectionLanguageScope(range: range) else { return nil }
    let bookID = document.book.id
    let chapter = document.selectedChapter
    return UIAction(title: L10n.string("language.passage"), image: UIImage(systemName: "globe")) { [weak self] _ in
        self?.chooseSelectionLanguage(scope, bookID: bookID, chapter: chapter)
    }
}

private func chooseSelectionLanguage(_ scope: PassageLanguageCorrection, bookID: String, chapter: Int) {
    Task { [weak self] in
        await BookLanguagePicker.edit(bookID: bookID, passage: scope, isCurrent: { [weak self] in
            self?.document.book.id == bookID && self?.document.selectedChapter == chapter && self?.isCurrentBook() == true
        })
    }
}

    private func promptForNote(_ selection: ReaderHighlightEditor.Selection) {
        let alert = UIAlertController(
            title: L10n.string("reader.action.addNote"), message: selection.text, preferredStyle: .alert
        )
        alert.addTextField { $0.placeholder = L10n.string("reader.note.placeholder") }
        alert.addAction(UIAlertAction(title: L10n.string("common.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("common.save"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            // Stored against the chapter the text was selected in, even if the reader
            // moved on (for example by following playback) while the alert was open.
            self.highlightEditor.addNote(selection, note: alert?.textFields?.first?.text)
            if self.isCurrent(selection) { self.repaintSavedHighlights(chapterIndex: selection.chapterIndex) }
        })
        present(alert)
    }

    // MARK: - Footnotes

    func showFootnotes() {
        guard let footnotes = document.chapter(at: document.selectedChapter)?.footnotes,
              !footnotes.isEmpty else { return }
        let sheet = ReaderFootnotesSheet(footnotes: footnotes)
        present(UINavigationController(rootViewController: sheet))
    }

    // MARK: - Book search

    func promptSearch() { search.promptSearch() }
    func performSearch(query: String) { search.performSearch(query: query) }
    func waitForSearchCompletion() async { await search.waitForCompletion() }
    func cancelSearch() { search.cancel() }

}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
