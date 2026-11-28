import Foundation

/// Renaming for one open contents list, addressed by row position.
struct ContentsRenaming {
    let actions: @MainActor (Int) -> [ChapterRenaming.Action]
    /// A nil name restores the automatic one. Returns the new rows, or nil if the book changed.
    let apply: @MainActor (Int, String?) throws -> [ReaderTocRow]?
}

/// What a contents row offers, shared by the iOS and Mac contents lists.
@MainActor
struct ChapterRenaming {
    struct Action: Equatable {
        enum Kind { case rename, restore }
        let kind: Kind
        var title: String { L10n.string(kind == .rename ? "toc.rename" : "toc.restoreName") }
    }

    var store: ChapterNameStore = .shared
    /// Tells Now Playing about the new title; the index is the 0-based EPUB axis.
    var publish: (String, Int) -> Void

    /// A PDF contents row is a narration chapter of the page map, not parsed book text.
    func actions(forPDFChapter key: Int, names: [Int: String]) -> [Action] {
        [Action(kind: .rename)] + (names[key] == nil ? [] : [Action(kind: .restore)])
    }

    func actions(for row: ReaderTocRow, in document: ReaderDocument) -> [Action] {
        guard let chapter = chapter(for: row, in: document) else { return [] }
        return [Action(kind: .rename)] + (chapter.customName == nil ? [] : [Action(kind: .restore)])
    }

    func apply(_ name: String?, to row: ReaderTocRow, in document: ReaderDocument, bookID: String) throws {
        guard let position = row.chapterIndex, let chapter = chapter(for: row, in: document) else { return }
        document.chapterNames = try store.set(bookID: bookID, chapter: chapter.index, name: name)
        if let updated = document.fulltext?.chapters[position] {
            publish(updated.displayTitle, updated.zeroBasedEpubIndex)
        }
    }

    /// Only the row that opens a chapter names it; a section inside it keeps the book's title.
    private func chapter(for row: ReaderTocRow, in document: ReaderDocument) -> EbookFulltext.Chapter? {
        guard row.opensChapter, let position = row.chapterIndex,
              let chapters = document.fulltext?.chapters, chapters.indices.contains(position) else { return nil }
        return chapters[position]
    }
}
