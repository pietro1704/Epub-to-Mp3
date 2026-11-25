#if os(macOS)
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

var onPlayFromHere: ((Int, Double) -> Void)?
private lazy var highlightEditor = ReaderHighlightEditor(store: bookmarkStore)

func repaintSavedHighlights(chapterIndex: Int) {
    guard let bookID = currentBookId, let storage = textView.textStorage else { return }
    let selection = textView.selectedRange()
    storage.setAttributedString(ReaderSavedHighlights.repaint(storage,
        highlights: highlightEditor.highlights(bookID: bookID, chapterIndex: chapterIndex)))
    textView.setSelectedRange(selection)
}

func buildSelectionMenuItems(range: NSRange) -> [NSMenuItem] {
    guard let bookID = currentBookId, let storage = textView.textStorage,
          let selection = highlightEditor.selection(range: range, in: storage, bookID: bookID,
              chapterIndex: selectedChapter, chapterTitle: chapter(at: selectedChapter)?.displayTitle ?? "") else { return [] }
    func item(_ key: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: L10n.string(key), action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = selection
        return item
    }
    let play = item("reader.action.playFromHere", #selector(playFromSelection(_:)))
    let change = item(selection.existing == nil ? "reader.action.highlight" : "reader.action.removeHighlight",
                      #selector(highlightSelectionFromMenu(_:)))
    let note = item("reader.action.addNote", #selector(addNoteForSelectionFromMenu(_:)))
    let more = NSMenuItem(title: L10n.string("reader.selection.more"), action: nil, keyEquivalent: "")
    let submenu = NSMenu()
    submenu.addItem(change)
    submenu.addItem(note)
    if let language = selectionLanguageMenuItem(range: range) { submenu.addItem(language) }
    more.submenu = submenu
    return [play, more]
}

private func currentSelection(_ sender: NSMenuItem) -> ReaderHighlightEditor.Selection? {
    guard let selection = sender.representedObject as? ReaderHighlightEditor.Selection,
          ReaderHighlightEditor.isCurrent(selection, bookID: currentBookId, chapterIndex: selectedChapter) else { return nil }
    return selection
}

@objc private func playFromSelection(_ sender: NSMenuItem) {
    guard let selection = currentSelection(sender), let storage = textView.textStorage,
          let source = chapter(at: selectedChapter),
          let ratio = ReaderSavedHighlights.playbackRatio(selection: highlightEditor.playbackRange(for: selection, in: storage),
              rendered: textView.string, source: source.text) else { return }
    // Play from here leaves the selection mode: no selection stays behind the narration.
    textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
    onPlayFromHere?(source.zeroBasedEpubIndex, ratio)
}

@objc private func highlightSelectionFromMenu(_ sender: NSMenuItem) {
    guard let selection = currentSelection(sender) else { return }
    highlightEditor.toggleHighlight(selection)
    repaintSavedHighlights(chapterIndex: selection.chapterIndex)
}

@objc private func addNoteForSelectionFromMenu(_ sender: NSMenuItem) {
    guard let selection = currentSelection(sender) else { return }
    promptForNote(selection)
}

private func selectionLanguageMenuItem(range: NSRange) -> NSMenuItem? {
    guard let bookID = currentBookId, let source = chapter(at: selectedChapter),
          let scope = ReaderLanguageSelection.passage(rendered: textView.string, range: range,
              source: source.text, chapterIndex: source.zeroBasedEpubIndex) else { return nil }
    let item = NSMenuItem(title: L10n.string("language.passage"), action: #selector(changeSelectionLanguage(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = ReaderLanguageSelectionContext(bookID: bookID, readerChapter: selectedChapter, scope: scope)
    return item
}

@objc private func changeSelectionLanguage(_ sender: NSMenuItem) {
    guard let context = sender.representedObject as? ReaderLanguageSelectionContext,
          context.bookID == currentBookId, context.readerChapter == selectedChapter else { return }
    Task { [weak self] in
        await BookLanguagePicker.edit(bookID: context.bookID, passage: context.scope, isCurrent: { [weak self] in
            self?.currentBookId == context.bookID && self?.selectedChapter == context.readerChapter
        })
    }
}

    private func promptForNote(_ selection: ReaderHighlightEditor.Selection) {
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.action.addNote")
        alert.informativeText = selection.text
        alert.addButton(withTitle: L10n.string("common.save"))
        alert.addButton(withTitle: L10n.string("common.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = L10n.string("reader.note.placeholder")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Stored against the chapter the text was selected in, even if the reader moved on.
        highlightEditor.addNote(selection, note: field.stringValue)
        if ReaderHighlightEditor.isCurrent(selection, bookID: currentBookId, chapterIndex: selectedChapter) {
            repaintSavedHighlights(chapterIndex: selection.chapterIndex)
        }
    }

    // MARK: - Footnotes

    /// Native alert listing `{number, text}` pairs for the current
    /// chapter — no attempt to resolve a tap-to-jump from an inline
    /// reference (see the iOS `ReaderFootnotesSheet` doc comment for
    /// why that's fragile).
    func showFootnotes() {
        guard let footnotes = chapter(at: selectedChapter)?.footnotes, !footnotes.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("reader.footnotes.title")
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 220))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.string = footnotes.enumerated()
            .map { "\($1.number ?? String($0 + 1)). \($1.text)" }
            .joined(separator: "\n\n")
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        alert.accessoryView = scrollView
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
        for chapterIndex in order where !chapters[chapterIndex].isImageOnly {
            // The parser text only picks candidate chapters. The selection
            // range must come from the rendered text the view shows, whose
            // offsets differ from the parser text for HTML chapters.
            if chapterIndex != selectedChapter {
                let parserText = chapters[chapterIndex].text as NSString
                guard parserText.range(of: query, options: .caseInsensitive).location != NSNotFound else { continue }
                persistReadingProgress()
                selectedChapter = chapterIndex
                showChapter(chapterIndex)
            }
            let range = (textView.string as NSString).range(of: query, options: .caseInsensitive)
            guard range.location != NSNotFound else { continue }
            textView.setSelectedRange(range)
            if MacReaderTextLayout.showsColumns(textView),
               let height = textView.enclosingScrollView?.contentView.bounds.height,
               let line = MacReaderTextLayout.lineRect(forCharacterAt: range.location, in: textView) {
                textView.scroll(NSPoint(x: 0, y: (line.minY / height).rounded(.down) * height))
            } else {
                textView.scrollRangeToVisible(range)
            }
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
