import Foundation

/// Selection → highlight and note orchestration shared by the iOS and Mac readers.
///
/// A `Selection` is captured when the selection menu is built and carries the book,
/// reader chapter and chapter title of that moment. Every write uses those captured
/// values, so a note saved after the reader moved on still lands on the chapter the
/// text was selected in. Menus, prompts and repainting stay with each platform.
@MainActor
final class ReaderHighlightEditor {
    struct Selection {
        let range: NSRange
        let text: String
        let bookID: String
        let chapterIndex: Int
        let chapterTitle: String
        /// The saved highlight under the selection, if any.
        let existing: Bookmark?
    }

    enum Outcome: Equatable {
        case added(Bookmark)
        case removed(UUID)
    }

    private let store: BookmarkStore

    init(store: BookmarkStore) { self.store = store }

    func highlights(bookID: String, chapterIndex: Int) -> [Bookmark] {
        store.bookmarks(for: bookID, chapterIndex: chapterIndex)
    }

    /// Nil when the range is not a non-empty range inside `text`.
    func selection(range: NSRange, in text: NSAttributedString, bookID: String,
                   chapterIndex: Int, chapterTitle: String) -> Selection? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location < text.length, range.length <= text.length - range.location else { return nil }
        let existing = ReaderSavedHighlights.target(at: range,
            highlights: highlights(bookID: bookID, chapterIndex: chapterIndex), in: text)
        return Selection(range: range, text: (text.string as NSString).substring(with: range), bookID: bookID,
                         chapterIndex: chapterIndex, chapterTitle: chapterTitle, existing: existing)
    }

    static func isCurrent(_ selection: Selection, bookID: String?, chapterIndex: Int) -> Bool {
        selection.bookID == bookID && selection.chapterIndex == chapterIndex
    }

    /// Removes the highlight under the selection, or adds one for the selected text.
    @discardableResult
    func toggleHighlight(_ selection: Selection) -> Outcome {
        if let existing = selection.existing {
            store.remove(id: existing.id)
            return .removed(existing.id)
        }
        return .added(write(selection, note: nil))
    }

    @discardableResult
    func addNote(_ selection: Selection, note: String?) -> Bookmark {
        // A note inside a saved highlight belongs to it; a second record would paint twice.
        if let existing = selection.existing {
            guard let note, !note.isEmpty else { return existing }
            if let updated = store.setNote(note, id: existing.id) { return updated }
        }
        return write(selection, note: note)
    }

    /// Playing from inside a saved highlight starts at the whole highlight, not at the
    /// partial selection.
    func playbackRange(for selection: Selection, in text: NSAttributedString) -> NSRange {
        selection.existing.flatMap { ReaderSavedHighlights.range(for: $0, in: text) } ?? selection.range
    }

    private func write(_ selection: Selection, note: String?) -> Bookmark {
        store.addBookmark(
            bookId: selection.bookID,
            chapterIndex: selection.chapterIndex,
            chapterTitle: selection.chapterTitle,
            startChar: selection.range.location,
            endChar: selection.range.location + selection.range.length,
            selectedText: selection.text,
            note: note,
            color: .yellow
        )
    }
}
