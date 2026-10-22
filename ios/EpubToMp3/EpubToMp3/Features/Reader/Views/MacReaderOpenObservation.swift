#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit

@MainActor
final class MacReaderOpenObservation {
    private let document: MacReaderDocument
    private let observeOpenStage: (String) -> Void
    private var activeBookOpenJourneyID: UUID? {
        get { document.activeBookOpenJourneyID }
        set { document.activeBookOpenJourneyID = newValue }
    }
    private var pendingPDFPageJourneyID: UUID? {
        get { document.pendingPDFPageJourneyID }
        set { document.pendingPDFPageJourneyID = newValue }
    }
    private var firstPDFPageReadyJourneyID: UUID? {
        get { document.firstPDFPageReadyJourneyID }
        set { document.firstPDFPageReadyJourneyID = newValue }
    }
    private var controlsReadyJourneyID: UUID? {
        get { document.controlsReadyJourneyID }
        set { document.controlsReadyJourneyID = newValue }
    }

    init(document: MacReaderDocument, stageObserver: (@Sendable (String, UInt64) -> Void)?) {
        self.document = document
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
    }

    static func documentKind(for book: BookEntity) -> LatencyObservation.DocumentKind {
        book.fileType == .pdf ? .selectableTextPDF : .epub
    }

    func recordReadableContent() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        observeOpenStage("readable_content")
        _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
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
        observeOpenStage("controls_usable")
        _ = LatencyObservationStore.shared.record(.controlsUsable, for: journeyID)
        if pendingPDFPageJourneyID == journeyID {
            controlsReadyJourneyID = journeyID
            finishPDFJourneyIfReady(journeyID)
        } else {
            LatencyObservationStore.shared.finish(journeyID)
            activeBookOpenJourneyID = nil
        }
    }

    private func finishPDFJourneyIfReady(_ journeyID: UUID) {
        guard firstPDFPageReadyJourneyID == journeyID,
              controlsReadyJourneyID == journeyID
        else {
            return
        }
        LatencyObservationStore.shared.finish(journeyID)
        activeBookOpenJourneyID = nil
        pendingPDFPageJourneyID = nil
        firstPDFPageReadyJourneyID = nil
        controlsReadyJourneyID = nil
    }

    func cancelActiveBookOpenJourney() {
        guard let journeyID = activeBookOpenJourneyID else { return }
        _ = LatencyObservationStore.shared.cancel(journeyID)
        activeBookOpenJourneyID = nil
        pendingPDFPageJourneyID = nil
        firstPDFPageReadyJourneyID = nil
        controlsReadyJourneyID = nil
    }

}
#endif
