#if os(iOS)
import Foundation

extension ReaderOpenJourney {
    /// Records usable controls only when the prepared snapshot on screen still
    /// matches its source and catalog. The Mac reader validates in its own caller
    /// and records without this check.
    func recordControlsUsable(preparedSnapshot snapshot: PreparedReaderChapterStore.Snapshot?, bookID: String) {
        guard activeBookOpenJourneyID != nil else { return }
        if let snapshot {
            guard let url = LocalFulltextCache.storageURL(bookId: bookID),
                  snapshot.catalogChapters?.count == snapshot.chapterCount,
                  PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: url) else { return }
            let catalog = snapshot.catalogChapters ?? []
            guard catalog.indices.contains(snapshot.chapterOrdinal),
                  catalog[snapshot.chapterOrdinal].index > 0,
                  catalog[snapshot.chapterOrdinal].index - 1 == snapshot.chapter.zeroBasedEpubIndex else { return }
        }
        recordControlsUsable()
    }
}
#endif
