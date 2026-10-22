#if os(iOS)
import UIKit

/// Owns prepared chapter validation and mounting order. UIKit geometry remains
/// committed by the controller through synchronous events and viewport facts.
@MainActor
final class ReaderPreparedPresentation {
    enum Event {
        case showChapter(Int, NSAttributedString?)
        case layoutScrollView
        case scheduleHostLayout(UUID)
        case requestHostLayout
        case layoutHostView
        case restorePosition(ReaderProgressStore.Entry)
        case updatePageIndicator
        case completeLoading
        case finishLoading(UUID)
        case publishTitles(EbookFulltext)
        case error(String)
    }

    private let document: ReaderBookDocument
    private let settings: AppSettings
    private let preparedRenderer: PreparedChapterRenderer
    private let preparedChapterStore: PreparedReaderChapterStore
    private let observeOpenStage: (String) -> Void
    private let viewportIsCommitted: () -> Bool
    private let textIsLaidOut: () -> Bool
    private let send: (Event) -> Void
    let restoration: ReaderPreparedRestoration

    init(document: ReaderBookDocument, settings: AppSettings, renderer: PreparedChapterRenderer,
         store: PreparedReaderChapterStore, stageObserver: (@Sendable (String, UInt64) -> Void)?,
         viewportIsCommitted: @escaping () -> Bool, textIsLaidOut: @escaping () -> Bool,
         send: @escaping (Event) -> Void) {
        self.document = document
        self.settings = settings
        preparedRenderer = renderer
        preparedChapterStore = store
        self.viewportIsCommitted = viewportIsCommitted
        self.textIsLaidOut = textIsLaidOut
        self.send = send
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
        // A separate weak bridge avoids retaining presentation through tasks.
        let bridge = ReaderPreparedPresentationBridge()
        restoration = ReaderPreparedRestoration(document: document, settings: settings,
            renderer: renderer, store: store, stageObserver: stageObserver) { [bridge] value, id, bookID in
            await bridge.presentation?.restorePreparedProjection(value, loadingID: id, bookID: bookID)
        }
        bridge.presentation = self
    }

    private func isCurrentLoad(_ loadingID: UUID, bookID: String) -> Bool {
        document.isCurrentLoad(loadingID, bookID: bookID)
    }

    func presentPreparedProjectionDuringCommittedLayoutIfReady() {
        guard document.pendingProjectionAnchor == nil,
              document.activePreparedChapter == nil,
              viewportIsCommitted(),
              let fulltextURL = LocalFulltextCache.storageURL(bookId: document.book.id),
              let restoration = restoration.slot.take() else { return }
        let snapshot = restoration.projection.snapshot
        guard let loadingID = document.activeLoadingID,
              isCurrentLoad(loadingID, bookID: document.book.id),
              PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: fulltextURL) else {
            observeOpenStage("projection_snapshot_rejected")
            return
        }

        let fontDirectoryURL = document.registeredFontURLs.first?.deletingLastPathComponent()
        let currentStyle = preparedRenderer.styleSnapshot(settings: settings, fontDirectoryURL: fontDirectoryURL)
        guard restoration.style == currentStyle else {
            self.restoration.slot.store(restoration)
            return
        }

        observeOpenStage("projection_snapshot_loaded")
        if let journeyID = document.activeBookOpenJourneyID {
            LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
        }
        if let rendererRestoration = restoration.renderer {
            preparedRenderer.cacheRestoration(
                rendererRestoration,
                bookID: document.book.id,
                chapterIndex: snapshot.chapterOrdinal
            )
        }
        observeOpenStage(restoration.renderer == nil
            ? "prepared_renderer_cache_miss" : "prepared_renderer_cache_hit")
        observeOpenStage("projection_presentation_started")
        document.activePreparedChapter = snapshot
        document.selectedChapter = snapshot.chapterOrdinal
        document.presentedProjectionLoadingID = loadingID
        document.pendingProjectionAnchor = (loadingID, restoration.projection.progress)
        document.pendingLoadingCompletionID = loadingID
        observeOpenStage("prepared_payload_display_started")
        send(.showChapter(document.selectedChapter, restoration.renderer?.attributedText))
        observeOpenStage("projection_chapter_mounted")
        observeOpenStage("projection_layout_started")
        send(.layoutScrollView)
        send(.scheduleHostLayout(loadingID))
    }

    func finishPreparedProjectionLayoutIfNeeded() {
        guard let pending = document.pendingProjectionAnchor,
              textIsLaidOut(),
              viewportIsCommitted() else { return }
        guard isCurrentLoad(pending.loadingID, bookID: document.book.id) else { return }
        document.pendingProjectionAnchor = nil
        send(.restorePosition(pending.progress))
        send(.updatePageIndicator)
        document.hasRestoredInitialPosition = true
        observeOpenStage("projection_layout_completed")
        observeOpenStage("prepared_payload_display_completed")
        observeOpenStage("projection_readiness_requested")
    }

    func restorePreparedProjection(
        _ restoration: PreparedProjectionRestoration?,
        loadingID: UUID,
        bookID: String
    ) async {
        guard document.presentedProjectionLoadingID != loadingID else { return }
        guard document.book.fileType != .pdf,
              let fulltextURL = LocalFulltextCache.storageURL(bookId: bookID) else {
            observeOpenStage("projection_snapshot_missing")
            return
        }
        guard let restoration else {
            observeOpenStage("projection_snapshot_missing")
            return
        }
        let preparedProjection = restoration.projection
        let snapshot = preparedProjection.snapshot
        let progress = preparedProjection.progress
        observeOpenStage("projection_snapshot_loaded")
        guard PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: fulltextURL),
              isCurrentLoad(loadingID, bookID: bookID) else {
            observeOpenStage("projection_snapshot_rejected")
            return
        }
        if let journeyID = document.activeBookOpenJourneyID {
            LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
        }
        let fontDirectoryURL = document.registeredFontURLs.first?.deletingLastPathComponent()
        let currentStyle = preparedRenderer.styleSnapshot(settings: settings, fontDirectoryURL: fontDirectoryURL)
        let preparedRendering: NSAttributedString?
        if restoration.style == currentStyle, let rendererRestoration = restoration.renderer {
            preparedRenderer.cacheRestoration(
                rendererRestoration,
                bookID: bookID,
                chapterIndex: snapshot.chapterOrdinal
            )
            preparedRendering = rendererRestoration.attributedText
        } else if restoration.style != currentStyle {
            preparedRendering = await preparedRenderer.restore(
                bookID: bookID,
                chapterIndex: snapshot.chapterOrdinal,
                chapter: snapshot.chapter,
                settings: settings,
                fontDirectoryURL: fontDirectoryURL
            )
        } else {
            preparedRendering = nil
        }
        observeOpenStage(preparedRendering == nil ? "prepared_renderer_cache_miss" : "prepared_renderer_cache_hit")
        guard !Task.isCancelled, isCurrentLoad(loadingID, bookID: bookID),
              PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: fulltextURL) else { return }
        presentPreparedProjection(
            snapshot,
            progress: progress,
            preparedRendering: preparedRendering,
            loadingID: loadingID,
            bookID: bookID,
            fulltextURL: fulltextURL
        )
    }

    func presentPreparedProjection(
        _ snapshot: PreparedReaderChapterStore.Snapshot,
        progress: ReaderProgressStore.Entry,
        preparedRendering: NSAttributedString?,
        loadingID: UUID,
        bookID: String,
        fulltextURL: URL
    ) {
        guard isCurrentLoad(loadingID, bookID: bookID),
              document.presentedProjectionLoadingID != loadingID,
              PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: fulltextURL) else { return }
        observeOpenStage("projection_presentation_started")
        document.activePreparedChapter = snapshot
        document.selectedChapter = snapshot.chapterOrdinal
        document.presentedProjectionLoadingID = loadingID
        send(.showChapter(document.selectedChapter, preparedRendering))
        observeOpenStage("projection_chapter_mounted")
        send(.requestHostLayout)
        observeOpenStage("projection_layout_started")
        send(.layoutHostView)
        observeOpenStage("projection_layout_completed")
        guard viewportIsCommitted() else { return }
        send(.restorePosition(progress))
        send(.updatePageIndicator)
        document.hasRestoredInitialPosition = true
        document.pendingLoadingCompletionID = loadingID
        observeOpenStage("projection_readiness_requested")
        send(.completeLoading)
    }

    func attachHydratedCatalog(_ payload: EbookFulltext, loadingID: UUID) -> Bool {
        guard let snapshot = document.activePreparedChapter,
              snapshot.bookID == document.book.id,
              snapshot.chapterOrdinal == document.selectedChapter,
              snapshot.chapterCount == payload.chapters.count,
              snapshot.title == payload.bookTitle,
              snapshot.author == payload.bookAuthor,
              snapshot.toc == payload.toc,
              zip(snapshot.catalogChapters ?? [], payload.chapters).allSatisfy({
                  $0.index == $1.index && $0.name == $1.name && $0.contentKind == $1.contentKind
              }),
              payload.chapters.indices.contains(document.selectedChapter),
              snapshot.chapter == payload.chapters[document.selectedChapter] else { return false }
        guard isCurrentLoad(loadingID, bookID: document.book.id) else { return true }
        document.fulltext = payload
        document.activePreparedChapter = nil
        LocalFulltextCache.recordWarmOpen(bookId: document.book.id)
        send(.publishTitles(payload))
        if let journeyID = document.activeBookOpenJourneyID {
            LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
        }
        return true
    }

    func preparedChapterIndex(in payload: EbookFulltext) -> Int? {
        var index = document.selectedChapter
        if !document.hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: document.book.id) {
            index = entry.chapterIndex
        } else if !document.hasRestoredInitialPosition, index == 0 {
            index = ReaderInitialChapter.firstSubstantiveIndex(in: payload.chapters)
        }
        return ReaderInitialChapter.index(selectedChapter: index, chapterCount: payload.chapters.count)
    }

    func restorePreparedChapter(in payload: EbookFulltext) async -> NSAttributedString? {
        guard let index = preparedChapterIndex(in: payload), !payload.chapters[index].isImageOnly else { return nil }
        return await preparedRenderer.restore(bookID: document.book.id, chapterIndex: index, chapter: payload.chapters[index],
            settings: settings, fontDirectoryURL: document.registeredFontURLs.first?.deletingLastPathComponent())
    }

    /// Applies prepared reader content after either a warm-cache hit or a
    /// cold parse. Keeping this path shared makes saved-position restoration
    /// identical in both cases while allowing the warm path to skip file I/O.
    func displayPreparedPayload(_ payload: EbookFulltext, loadingID: UUID,
                                        preparedRendering: NSAttributedString? = nil) {
        guard isCurrentLoad(loadingID, bookID: document.book.id) else { return }
        guard !payload.chapters.isEmpty else {
            send(.error(L10n.string("reader.noReadableContent")))
            return
        }
        document.fulltext = payload
        LocalFulltextCache.recordWarmOpen(bookId: document.book.id)
        send(.publishTitles(payload))
        if !document.hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: document.book.id) {
            document.selectedChapter = entry.chapterIndex
        } else if !document.hasRestoredInitialPosition, document.selectedChapter == 0 {
            // Many EPUBs put a cover, title page, and contents page before
            // the first readable passage. Saved progress still wins.
            document.selectedChapter = ReaderInitialChapter.firstSubstantiveIndex(in: payload.chapters)
        }
        guard let selectedChapter = ReaderInitialChapter.index(
            selectedChapter: document.selectedChapter,
            chapterCount: payload.chapters.count
        ) else {
            send(.error(L10n.string("reader.noReadableContent")))
            return
        }
        document.selectedChapter = selectedChapter
        send(.showChapter(document.selectedChapter, preparedRendering))
        prepareChapterProjection(ordinal: selectedChapter)
        send(.finishLoading(loadingID))
    }

    func prepareChapterProjection(ordinal: Int) {
        guard ordinal != document.lastPreparedProjectionOrdinal,
              let fulltextURL = LocalFulltextCache.storageURL(bookId: document.book.id) else { return }
        document.lastPreparedProjectionOrdinal = ordinal
        let bookID = document.book.id
        let store = preparedChapterStore
        Task.detached(priority: .utility) {
            try? await store.write(bookID: bookID, chapterOrdinal: ordinal, fulltextURL: fulltextURL)
        }
    }

}

@MainActor
private final class ReaderPreparedPresentationBridge {
    weak var presentation: ReaderPreparedPresentation?
}
#endif
