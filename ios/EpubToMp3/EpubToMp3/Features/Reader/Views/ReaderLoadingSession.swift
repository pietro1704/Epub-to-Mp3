#if os(iOS)
import UIKit

/// Owns loading-cover readiness and deferred gesture activation. Document IO
/// and committed text geometry are provided by their respective owners.
@MainActor
final class ReaderLoadingSession {
    private let document: ReaderBookDocument
    private let composition: ReaderViewComposition
    private let settings: AppSettings
    private let textPresentation: ReaderTextPresentation
    private let readingPosition: ReaderReadingPosition
    private let observation: ReaderOpenObservation
    private let deferInitialReaderGestures: Bool
    private let observeOpenStage: (String) -> Void
    private let scheduleReaderSettingsUpdate: () -> Void
    private let onLoadStateChanged: (Bool) -> Void
    private let onChromeVisibilityRequested: (Bool) -> Void
    private var loadTask: Task<Void, Never>?
    private(set) var isLoadingContent = false
    private(set) var isDeferringReaderGestures = false

    init(document: ReaderBookDocument, composition: ReaderViewComposition, settings: AppSettings,
         textPresentation: ReaderTextPresentation, readingPosition: ReaderReadingPosition,
         observation: ReaderOpenObservation, deferInitialReaderGestures: Bool,
         stageObserver: (@Sendable (String, UInt64) -> Void)?,
         scheduleReaderSettingsUpdate: @escaping () -> Void,
         onLoadStateChanged: @escaping (Bool) -> Void, onChromeVisibilityRequested: @escaping (Bool) -> Void) {
        self.document = document
        self.composition = composition
        self.settings = settings
        self.textPresentation = textPresentation
        self.readingPosition = readingPosition
        self.observation = observation
        self.deferInitialReaderGestures = deferInitialReaderGestures
        self.scheduleReaderSettingsUpdate = scheduleReaderSettingsUpdate
        self.onLoadStateChanged = onLoadStateChanged
        self.onChromeVisibilityRequested = onChromeVisibilityRequested
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
    }

    deinit { loadTask?.cancel() }
    func cancelFixture() { loadTask?.cancel(); loadTask = nil }
    func loadUITestFixture() { loadUITestFixture(after: uiTestLoadingDelay) }
    private func isCurrentLoad(_ id: UUID, bookID: String) -> Bool { document.isCurrentLoad(id, bookID: bookID) }

    /// Cover + spinner only — no TOC, footnotes, search, or "loading" text
    /// wall. Tapping a book must show that book, not a chooser; this
    /// overlay sits full-screen above everything else until content lands.
    func showLoadingOverlay() {
        isLoadingContent = true
        isDeferringReaderGestures = true
        composition.pageTap.isEnabled = false
        composition.scrollView.isScrollEnabled = false
        composition.scrollView.panGestureRecognizer.isEnabled = false
        composition.loadingContainer.isHidden = false
        composition.loadingSpinner.startAnimating()
        composition.loadingStatusLabel.text = nil
        composition.loadingRetryButton.isHidden = true
        if let cover = document.book.coverPNG, let image = UIImage(data: cover) {
            composition.loadingCoverView.image = image
            composition.loadingCoverView.backgroundColor = .clear
        } else {
            composition.loadingCoverView.image = UIImage(systemName: "book.closed")
            composition.loadingCoverView.backgroundColor = .secondarySystemFill
        }
        onLoadStateChanged(true)
    }

    func hideLoadingOverlay() {
        observeOpenStage("reader_loading_hide_started")
        document.activeLoadingID = nil
        document.pendingLoadingCompletionID = nil
        composition.loadingSpinner.stopAnimating()
        composition.loadingContainer.isHidden = true
        // A tap that opened a library cell can finish while this child is
        // being embedded. Always present freshly loaded content with chrome
        // visible; the first intentional reader tap can then enter immersive
        // mode without stealing the book-opening gesture.
        isLoadingContent = false
        textPresentation.synchronizeChromeVisibility()
        onChromeVisibilityRequested(false)
        observeOpenStage("reader_loading_chrome_callback_completed")
        onLoadStateChanged(false)
        observeOpenStage("reader_loading_root_callback_completed")
        if textPresentation.lastRenderedTextSettings != ReaderTextSettings(settings: settings) {
            scheduleReaderSettingsUpdate()
        }
        guard deferInitialReaderGestures else {
            isDeferringReaderGestures = false
            composition.pageTap.isEnabled = true
            textPresentation.applyReaderLayoutMode()
            observeOpenStage("reader_controls_enabled")
            observation.recordControlsUsable()
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.document.activeLoadingID == nil,
                  self.composition.loadingContainer.isHidden else { return }
            self.isDeferringReaderGestures = false
            self.composition.pageTap.isEnabled = true
            self.textPresentation.applyReaderLayoutMode()
            self.observeOpenStage("reader_controls_enabled")
            self.observation.recordControlsUsable()
        }
    }

    /// Parsing failed (both the embedded interpreter and, per
    /// the backend fulltext request, its native fallback). Stop the spinner —
    /// an error is a terminal state, never an infinite spinner — and show
    /// the reason under the cover instead of leaving the loading screen.
    func showLoadingError(_ message: String) {
        observation.cancelActiveBookOpenJourney()
        document.activeLoadingID = nil
        document.loadGenerationID = nil
        document.pendingLoadingCompletionID = nil
        composition.loadingSpinner.stopAnimating()
        composition.loadingStatusLabel.text = AppErrorReporter.message(message, context: "Reader loading")
        composition.loadingRetryButton.isHidden = false
        isLoadingContent = false
        onLoadStateChanged(false)
    }

    private var uiTestLoadingDelay: TimeInterval {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiTestLoadingDelayMilliseconds"),
              arguments.indices.contains(arguments.index(after: index)),
              let milliseconds = Double(arguments[arguments.index(after: index)]) else {
            return 0
        }
        return min(max(milliseconds, 0), 10_000) / 1_000
    }

    func loadUITestFixture(after delay: TimeInterval) {
        let loadingID = document.activeLoadingID
        let displayFixture = { [weak self] in
            guard let self,
                  let loadingID,
                  self.isCurrentLoad(loadingID, bookID: self.document.book.id) else { return }
            self.textPresentation.showUITestFixture()
            self.finishLoadingAfterStableTextLayout(loadingID)
        }
        guard delay > 0 else {
            displayFixture()
            return
        }
        loadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self,
                  let loadingID,
                  self.isCurrentLoad(loadingID, bookID: self.document.book.id) else { return }
            self.textPresentation.showUITestFixture()
            self.finishLoadingAfterStableTextLayout(loadingID)
        }
    }

    func finishLoadingAfterStableTextLayout(_ loadingID: UUID) {
        guard isCurrentLoad(loadingID, bookID: document.book.id) else { return }
        document.pendingLoadingCompletionID = loadingID
        textPresentation.requestTextLayoutRefresh()
    }

    func completeLoadingAfterStableTextLayoutIfNeeded() {
        guard let loadingID = document.pendingLoadingCompletionID,
              isCurrentLoad(loadingID, bookID: document.book.id),
              document.pendingProjectionAnchor == nil,
              composition.scrollView.bounds.width > 1,
              composition.scrollView.bounds.height > 1,
              composition.textView.attributedText.length > 0 || !composition.comicPageImageView.isHidden else {
            return
        }
        document.pendingLoadingCompletionID = nil
        readingPosition.restoreReadingProgressIfNeeded()
        if let journeyID = document.activeBookOpenJourneyID {
            _ = LatencyObservationStore.shared.record(.readableContent, for: journeyID)
            observeOpenStage("readable_content")
        }
        hideLoadingOverlay()
    }

}
#endif
