import Foundation

/// The latency journey of one book open, shared by the iOS and Mac readers.
///
/// A reader document owns exactly one journey. It holds the four journey IDs
/// and cancels a still-active journey when the document is released, so a book
/// switch or a closed reader never leaves a pending observation behind.
/// Platform code decides *when* each step happens; this type only owns the state
/// machine: a PDF journey finishes after both its first page and the usable
/// controls were recorded, every other journey finishes at usable controls.
@MainActor
final class ReaderOpenJourney {
    var activeBookOpenJourneyID: UUID?
    var pendingPDFPageJourneyID: UUID?
    var firstPDFPageReadyJourneyID: UUID?
    var controlsReadyJourneyID: UUID?
    /// Receives the stage name and a monotonic timestamp for each emitted stage.
    var stageObserver: (@Sendable (String, UInt64) -> Void)?

    deinit {
        if let journeyID = activeBookOpenJourneyID {
            _ = LatencyObservationStore.shared.cancel(journeyID)
        }
    }

    static func documentKind(for book: BookEntity) -> LatencyObservation.DocumentKind {
        book.fileType == .pdf ? .selectableTextPDF : .epub
    }

    /// Starts a journey for `book` and makes it the active one.
    @discardableResult
    func begin(for book: BookEntity) -> UUID {
        let journeyID = LatencyObservationStore.shared.beginBookOpen(documentKind: Self.documentKind(for: book))
        activeBookOpenJourneyID = journeyID
        return journeyID
    }

    func emitStage(_ name: String) {
        stageObserver?(name, DispatchTime.now().uptimeNanoseconds)
    }

    func recordReadableContent() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
        emitStage("readable_content")
    }

    func recordFirstPDFPage(wasNormalized: Bool) {
        guard let journeyID = pendingPDFPageJourneyID,
              journeyID == activeBookOpenJourneyID
        else {
            return
        }
        if wasNormalized {
            LatencyObservationStore.shared.classifyDocument(.normalizedScannedPDF, for: journeyID)
        }
        _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
        _ = LatencyObservationStore.shared.record(.firstPDFPage, for: journeyID)
        firstPDFPageReadyJourneyID = journeyID
        finishPDFJourneyIfReady(journeyID)
    }

    func recordControlsUsable() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.record(.controlsUsable, for: journeyID)
        emitStage("controls_usable")
        if pendingPDFPageJourneyID == journeyID {
            controlsReadyJourneyID = journeyID
            finishPDFJourneyIfReady(journeyID)
        } else {
            LatencyObservationStore.shared.finish(journeyID)
            activeBookOpenJourneyID = nil
        }
    }

    func cancelActiveBookOpenJourney() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.cancel(journeyID)
        clear()
    }

    private func finishPDFJourneyIfReady(_ journeyID: UUID) {
        guard firstPDFPageReadyJourneyID == journeyID,
              controlsReadyJourneyID == journeyID
        else {
            return
        }
        LatencyObservationStore.shared.finish(journeyID)
        clear()
    }

    private func clear() {
        activeBookOpenJourneyID = nil
        pendingPDFPageJourneyID = nil
        firstPDFPageReadyJourneyID = nil
        controlsReadyJourneyID = nil
    }
}
