#if os(iOS)
import Foundation

@MainActor
final class ReaderOpenObservation {
    private let document: ReaderBookDocument
    private let observeOpenStage: (String) -> Void

    init(document: ReaderBookDocument, stageObserver: (@Sendable (String, UInt64) -> Void)?) {
        self.document = document
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
    }

    func recordFirstPDFPage(wasNormalized: Bool) {
        guard let journeyID = document.pendingPDFPageJourneyID,
              journeyID == document.activeBookOpenJourneyID
        else {
            return
        }
        if wasNormalized {
            LatencyObservationStore.shared.classifyDocument(.normalizedScannedPDF, for: journeyID)
        }
        _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
        _ = LatencyObservationStore.shared.record(.firstPDFPage, for: journeyID)
        document.firstPDFPageReadyJourneyID = journeyID
        finishPDFJourneyIfReady(journeyID)
    }

    func recordControlsUsable() {
        guard let journeyID = document.activeBookOpenJourneyID else { return }
        if let snapshot = document.activePreparedChapter {
            guard let url = LocalFulltextCache.storageURL(bookId: document.book.id),
                  snapshot.catalogChapters?.count == snapshot.chapterCount,
                  PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: url) else { return }
            let catalog = snapshot.catalogChapters ?? []
            guard catalog.indices.contains(snapshot.chapterOrdinal),
                  catalog[snapshot.chapterOrdinal].index > 0,
                  catalog[snapshot.chapterOrdinal].index - 1 == snapshot.chapter.zeroBasedEpubIndex else { return }
        }
        _ = LatencyObservationStore.shared.record(.controlsUsable, for: journeyID)
        observeOpenStage("controls_usable")
        if document.pendingPDFPageJourneyID == journeyID {
            document.controlsReadyJourneyID = journeyID
            finishPDFJourneyIfReady(journeyID)
        } else {
            LatencyObservationStore.shared.finish(journeyID)
            document.activeBookOpenJourneyID = nil
        }
    }

    private func finishPDFJourneyIfReady(_ journeyID: UUID) {
        guard document.firstPDFPageReadyJourneyID == journeyID,
              document.controlsReadyJourneyID == journeyID
        else {
            return
        }
        LatencyObservationStore.shared.finish(journeyID)
        document.activeBookOpenJourneyID = nil
        document.pendingPDFPageJourneyID = nil
        document.firstPDFPageReadyJourneyID = nil
        document.controlsReadyJourneyID = nil
    }

    func cancelActiveBookOpenJourney() {
        guard let journeyID = document.activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.cancel(journeyID)
        document.activeBookOpenJourneyID = nil
        document.pendingPDFPageJourneyID = nil
        document.firstPDFPageReadyJourneyID = nil
        document.controlsReadyJourneyID = nil
    }

}
#endif
