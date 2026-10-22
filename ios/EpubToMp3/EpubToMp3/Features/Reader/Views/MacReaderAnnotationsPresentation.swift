#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit

@MainActor
final class MacReaderAnnotationsPresentation: NSObject {
    private let document: MacReaderDocument
    private let composition: MacReaderViewComposition
    private let bookmarkStore: BookmarkStore
    private let persistReadingProgress: () -> Void
    private let showChapter: (Int) -> Void
    private var textView: MacReaderTextView { composition.textView }
    private var view: NSView { composition.view }
    private var selectedChapter: Int {
        get { document.selectedChapter }
        set { document.selectedChapter = newValue }
    }
    private var fulltext: EbookFulltext? {
        get { document.fulltext }
        set { document.fulltext = newValue }
    }
    private var currentBookId: String? {
        get { document.currentBookId }
        set { document.currentBookId = newValue }
    }

    init(document: MacReaderDocument, composition: MacReaderViewComposition, bookmarkStore: BookmarkStore,
         persistProgress: @escaping () -> Void, showChapter: @escaping (Int) -> Void) {
        self.document = document
        self.composition = composition
        self.bookmarkStore = bookmarkStore
        persistReadingProgress = persistProgress
        self.showChapter = showChapter
        super.init()
    }

    private func chapter(at index: Int) -> EbookFulltext.Chapter? { document.chapter(at: index) }

    func handleReaderLink(_ url: URL, linkText: String) -> Bool {
        guard let fulltext, let chapter = fulltext.chapters[safe: selectedChapter] else {
            return true
        }
        switch ReaderLinkResolver.destination(
            for: url,
            linkText: linkText,
            currentChapter: chapter,
            chapters: fulltext.chapters
        ) {
        case .chapter(let index):
            guard fulltext.chapters.indices.contains(index) else { return true }
            persistReadingProgress()
            selectedChapter = index
            showChapter(index)
            return true
        case .footnote(let footnote):
            showFootnote(footnote)
            return true
        case .external:
            return false
        case .unresolved:
            return true
        }
    }

    // MARK: - Selection → bookmark/highlight/note

    private struct PendingSelection {
        let range: NSRange
        let text: String
    }

    /// Repaints every saved highlight for this chapter as a background
    /// tint, resolved against the text actually on screen right now
    /// (`ReaderTextHighlight`), not the Python `chapter.text` pipeline.
    func repaintSavedHighlights(chapterIndex: Int) {
        guard let bookId = currentBookId else { return }
        let highlights = bookmarkStore.bookmarks(for: bookId, chapterIndex: chapterIndex).filter { $0.isHighlight }
        guard !highlights.isEmpty, let storage = textView.textStorage, storage.length > 0 else { return }
        for bookmark in highlights {
            let span = SentenceSpan(
                id: bookmark.id.uuidString, text: bookmark.selectedText,
                startChar: bookmark.startChar, endChar: bookmark.endChar
            )
            guard let range = ReaderTextHighlight.range(for: span, in: storage) else { continue }
            storage.addAttribute(.backgroundColor, value: bookmark.color.platformColor, range: range)
        }
    }

    func buildSelectionMenuItems(range: NSRange) -> [NSMenuItem] {
        let full = textView.string as NSString
        guard range.location + range.length <= full.length else { return [] }
        let selectedText = full.substring(with: range)
        let payload = PendingSelection(range: range, text: selectedText)

        let highlight = NSMenuItem(
            title: L10n.string("reader.action.highlight"),
            action: #selector(highlightSelectionFromMenu(_:)), keyEquivalent: ""
        )
        highlight.target = self
        highlight.representedObject = payload

        let note = NSMenuItem(
            title: L10n.string("reader.action.addNote"),
            action: #selector(addNoteForSelectionFromMenu(_:)), keyEquivalent: ""
        )
        note.target = self
        note.representedObject = payload

        return [highlight, note]
    }

    @objc private func highlightSelectionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? PendingSelection else { return }
        addBookmark(range: payload.range, selectedText: payload.text, note: nil)
    }

    @objc private func addNoteForSelectionFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? PendingSelection else { return }
        promptForNote(range: payload.range, selectedText: payload.text)
    }

    private func promptForNote(range: NSRange, selectedText: String) {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.action.addNote")
        alert.informativeText = selectedText
        alert.addButton(withTitle: L10n.string("common.save"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L10n.string("reader.note.placeholder")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addBookmark(range: range, selectedText: selectedText, note: field.stringValue)
    }

    private func addBookmark(range: NSRange, selectedText: String, note: String?) {
        guard let bookId = currentBookId else { return }
        bookmarkStore.addBookmark(
            bookId: bookId,
            chapterIndex: selectedChapter,
            chapterTitle: chapter(at: selectedChapter)?.name ?? "",
            startChar: range.location,
            endChar: range.location + range.length,
            selectedText: selectedText,
            note: note,
            color: .yellow
        )
        repaintSavedHighlights(chapterIndex: selectedChapter)
    }

    // MARK: - Footnotes

    /// Native alert listing `{number, text}` pairs for the current
    /// chapter — no attempt to resolve a tap-to-jump from an inline
    /// reference (see the iOS `ReaderFootnotesSheet` doc comment for
    /// why that's fragile).
    func showFootnotes() {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.footnotes.title")
        let footnotes = chapter(at: selectedChapter)?.footnotes ?? []
        if footnotes.isEmpty {
            alert.informativeText = L10n.string("reader.footnotes.empty")
        } else {
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = false
            textView.string = footnotes.enumerated()
                .map { "\($1.number ?? String($0 + 1)). \($1.text)" }
                .joined(separator: "\n\n")
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            alert.accessoryView = scrollView
        }
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

    private func showFootnote(_ footnote: EbookFulltext.Footnote) {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.footnotes.title")
        let numberPrefix = footnote.number.map { "\($0)\n\n" } ?? ""
        alert.informativeText = numberPrefix + footnote.text
        alert.addButton(withTitle: L10n.string("common.ok"))
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - In-chapter search

    func promptSearch() {
        guard fulltext != nil else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.search.placeholder")
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        performSearch(query: field.stringValue)
    }

    func performSearch(query: String) {
        guard let chapters = fulltext?.chapters, !chapters.isEmpty else { return }
        let order = Array(chapters.indices.dropFirst(selectedChapter))
            + Array(chapters.indices.prefix(selectedChapter + 1))
        for chapterIndex in order {
            let full = chapters[chapterIndex].text as NSString
            let range = full.range(of: query, options: .caseInsensitive)
            guard range.location != NSNotFound else { continue }
            if chapterIndex != selectedChapter {
                persistReadingProgress()
                selectedChapter = chapterIndex
                showChapter(chapterIndex)
            }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            return
        }
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.search.noResults")
        alert.addButton(withTitle: L10n.string("common.ok"))
        alert.runModal()
    }

}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
