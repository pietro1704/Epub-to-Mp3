import Foundation

extension PreparedReaderChapterStore.Snapshot {
    /// Selected text and authored navigation must agree before a visible
    /// projection can be kept when the full catalog arrives.
    func matchesCatalog(_ payload: EbookFulltext, bookID: String, chapterOrdinal: Int) -> Bool {
        guard self.bookID == bookID, self.chapterOrdinal == chapterOrdinal,
              chapterCount == payload.chapters.count, title == payload.bookTitle,
              author == payload.bookAuthor, toc == payload.toc,
              payload.chapters.indices.contains(chapterOrdinal),
              chapter == payload.chapters[chapterOrdinal] else { return false }
        guard let catalogChapters else { return true }
        return catalogChapters.count == payload.chapters.count
            && zip(catalogChapters, payload.chapters).allSatisfy {
                $0.index == $1.index && $0.name == $1.name && $0.contentKind == $1.contentKind
            }
    }
}
