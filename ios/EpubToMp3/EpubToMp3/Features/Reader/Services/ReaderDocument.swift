import Foundation

/// The content a reader owns for one open book, shared by the iOS and Mac
/// readers. Identity, load generations and presentation flags stay on the
/// platform subclasses until the book-open machine absorbs them.
@MainActor
class ReaderDocument {
    var fulltext: EbookFulltext?
    var activePreparedChapter: PreparedReaderChapterStore.Snapshot?
    var lastPreparedChapterOrdinal: Int?
    var registeredFontURLs: [URL] = []
    var selectedChapter: Int = 0
    var hasRestoredInitialPosition: Bool = false
    let openJourney = ReaderOpenJourney()

    var fontDirectoryURL: URL? { registeredFontURLs.first?.deletingLastPathComponent() }

    /// A load is current only for the generation and book that started it.
    /// Cancellation is not part of the rule: the Mac adds it in `isActiveLoad`
    /// and iOS never had it. Unifying that is a behavior change for the book-open
    /// machine (WP-11b), not for this move.
    static func isCurrentLoad<Generation: Equatable>(
        generation: Generation, current: Generation?, bookID: String, currentBookID: String?
    ) -> Bool {
        generation == current && currentBookID == bookID
    }

    func chapter(at ordinal: Int) -> EbookFulltext.Chapter? {
        if let fulltext { return fulltext.chapters.indices.contains(ordinal) ? fulltext.chapters[ordinal] : nil }
        return activePreparedChapter?.chapterOrdinal == ordinal ? activePreparedChapter?.chapter : nil
    }

    var tocRows: [ReaderTocRow] {
        guard let fulltext else { return [] }
        return ReaderTocFlattener.rows(toc: fulltext.toc, chapters: fulltext.chapters)
    }
}
