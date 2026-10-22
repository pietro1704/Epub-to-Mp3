#if os(iOS)
import UIKit

/// The source identity and content currently owned by a reader document.
/// Loading generations survive the loading cover so late catalog hydration can
/// be accepted only for the same source, while visible readiness has its own ID.
@MainActor
final class ReaderBookDocument {
    var book: BookEntity
    var fulltext: EbookFulltext?
    var activePreparedChapter: PreparedReaderChapterStore.Snapshot?
    var lastPreparedProjectionOrdinal: Int?
    var registeredFontURLs: [URL] = []
    var selectedChapter: Int = 0
    var hasRestoredInitialPosition: Bool = false
    var activeLoadingID: UUID?
    var loadGenerationID: UUID?
    var pendingLoadingCompletionID: UUID?
    var pendingProjectionAnchor: (loadingID: UUID, progress: ReaderProgressStore.Entry)?
    var presentedProjectionLoadingID: UUID?
    var activeBookOpenJourneyID: UUID?
    var pendingPDFPageJourneyID: UUID?
    var firstPDFPageReadyJourneyID: UUID?
    var controlsReadyJourneyID: UUID?

    init(book: BookEntity) { self.book = book }

    deinit {
        if let journeyID = activeBookOpenJourneyID {
            _ = LatencyObservationStore.shared.cancel(journeyID)
        }
    }

    func isCurrentLoad(_ loadingID: UUID, bookID: String) -> Bool {
        loadGenerationID == loadingID && book.id == bookID
    }
}
#endif
