#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit

/// Owns Mac book IO, prepared arrivals and source-bound publication ordering.
@MainActor
final class MacReaderBookLoad {
    enum Event {
        case resetTextSurface, empty, hideLoading, reloadContents, selectCurrentContents
        case warmHeader(BookEntity, Int), clearForLoad(BookEntity), showLoading(BookEntity)
        case chapterCount(Int), selectRow(Int), failure(Error)
    }
    private let document: MacReaderDocument
    private let library: LibraryStore
    private let settings: AppSettings
    private let preparedRenderer: PreparedChapterRenderer
    private let preparedChapterStore: PreparedReaderChapterStore
    private let preparedFulltextReader: @Sendable (String) async -> EbookFulltext?
    private let preparedFulltextWriter: @Sendable (EbookFulltext, String) -> Void
    private let textPresentation: MacReaderTextPresentation
    private let observation: MacReaderOpenObservation
    private let openStageObserver: (@Sendable (String, UInt64) -> Void)?
    private let send: (Event) -> Void
    private var loadTask: Task<Void, Never>?
    private var preparedRead: MacReaderPreparedRead?
    private var tocRows: [ReaderTocRow] { document.tocRows }
    private var loadGeneration: UUID {
        get { document.loadGeneration }
        set { document.loadGeneration = newValue }
    }
    private var presentationGeneration: UUID {
        get { document.presentationGeneration }
        set { document.presentationGeneration = newValue }
    }
    private var activeBookOpenJourneyID: UUID? {
        get { document.activeBookOpenJourneyID }
        set { document.activeBookOpenJourneyID = newValue }
    }
    private var pendingPDFPageJourneyID: UUID? {
        get { document.pendingPDFPageJourneyID }
        set { document.pendingPDFPageJourneyID = newValue }
    }
    private var fulltext: EbookFulltext? {
        get { document.fulltext }
        set { document.fulltext = newValue }
    }
    private var activePreparedChapter: PreparedReaderChapterStore.Snapshot? {
        get { document.activePreparedChapter }
        set { document.activePreparedChapter = newValue }
    }
    private var lastPreparedChapterOrdinal: Int? {
        get { document.lastPreparedChapterOrdinal }
        set { document.lastPreparedChapterOrdinal = newValue }
    }
    private var selectedChapter: Int {
        get { document.selectedChapter }
        set { document.selectedChapter = newValue }
    }
    private var currentBookId: String? {
        get { document.currentBookId }
        set { document.currentBookId = newValue }
    }
    private var hasRestoredInitialPosition: Bool {
        get { document.hasRestoredInitialPosition }
        set { document.hasRestoredInitialPosition = newValue }
    }
    private var isRestoringInitialPosition: Bool {
        get { document.isRestoringInitialPosition }
        set { document.isRestoringInitialPosition = newValue }
    }
    private var pendingAppearanceRefresh: Bool {
        get { document.pendingAppearanceRefresh }
        set { document.pendingAppearanceRefresh = newValue }
    }

    init(document: MacReaderDocument, library: LibraryStore, settings: AppSettings,
         renderer: PreparedChapterRenderer, store: PreparedReaderChapterStore,
         readFulltext: @escaping @Sendable (String) async -> EbookFulltext?,
         writeFulltext: @escaping @Sendable (EbookFulltext, String) -> Void,
         textPresentation: MacReaderTextPresentation, observation: MacReaderOpenObservation,
         stageObserver: (@Sendable (String, UInt64) -> Void)?, send: @escaping (Event) -> Void) {
        self.document = document
        self.library = library
        self.settings = settings
        preparedRenderer = renderer
        preparedChapterStore = store
        preparedFulltextReader = readFulltext
        preparedFulltextWriter = writeFulltext
        self.textPresentation = textPresentation
        self.observation = observation
        openStageObserver = stageObserver
        self.send = send
    }

    deinit { loadTask?.cancel() }
    private func observeOpenStage(_ name: String) { openStageObserver?(name, DispatchTime.now().uptimeNanoseconds) }
    private func isActiveLoad(_ id: UUID, bookID: String) -> Bool { document.isActiveLoad(id, bookID: bookID) }

    func loadCurrentBook() {
        LocalFulltextCache.cancelPrewarming()
        loadTask?.cancel()
        preparedRead?.cancel()
        preparedRead = nil
        observation.cancelActiveBookOpenJourney()
        let generation = UUID()
        loadGeneration = generation
        presentationGeneration = UUID()
        isRestoringInitialPosition = false
        pendingAppearanceRefresh = false
        activePreparedChapter = nil
        lastPreparedChapterOrdinal = nil
        send(.resetTextSurface)
        let id = UserDefaults.standard.string(forKey: ReaderSessionState.currentlyReadingBookIDKey)
        guard let book = library.books.first(where: { $0.id == id }) else {
            fulltext = nil
            currentBookId = nil
            send(.empty)
            return
        }
        if currentBookId != book.id {
            currentBookId = book.id
            hasRestoredInitialPosition = false
        }
        let journeyID = LatencyObservationStore.shared.beginBookOpen(
            documentKind: MacReaderOpenObservation.documentKind(for: book)
        )
        observeOpenStage("journey_started")
        activeBookOpenJourneyID = journeyID
        // Process-warm reader opens must not clear the visible chapter or
        // show the loading cover. The last two prepared books are retained
        // in memory precisely so this route can paint immediately.
        if let warmPayload = LocalFulltextCache.inMemoryPayload(bookId: book.id),
           !warmPayload.chapters.isEmpty {
            LatencyObservationStore.shared.classifyCache(.inMemoryWarm, for: journeyID)
            fulltext = warmPayload
            LocalFulltextCache.recordWarmOpen(bookId: book.id)
            send(.warmHeader(book, warmPayload.chapters.count))
            if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
                selectedChapter = entry.chapterIndex
            }
            selectedChapter = min(max(selectedChapter, 0), max(0, warmPayload.chapters.count - 1))
            if let row = tocRows.firstIndex(where: { $0.chapterIndex == selectedChapter }) {
                send(.selectRow(row))
            }
            if let chapter = warmPayload.chapters[safe: selectedChapter],
               chapter.isImageOnly || preparedRenderer.cached(
                   bookID: book.id, chapterIndex: selectedChapter, chapter: chapter,
                   settings: settings, fontDirectoryURL: nil) != nil {
                presentLoadedChapter(bookID: book.id)
            } else {
                send(.showLoading(book))
                loadTask = Task { [weak self] in
                    guard let self else { return }
                    await textPresentation.restoreSelectedChapter(bookID: book.id)
                    guard isActiveLoad(generation, bookID: book.id) else { return }
                    presentLoadedChapter(bookID: book.id)
                }
            }
            return
        }
        let prepared = MacReaderPreparedRead(bookID: book.id, reader: preparedFulltextReader,
            store: preparedChapterStore, observe: openStageObserver)
        preparedRead = prepared
        let arrivals = prepared.arrivals
        let catalogTask = prepared.catalogTask
        let startCatalog = { prepared.startCatalog() }
        observeOpenStage("prepared_read_tasks_started")
        fulltext = nil
        send(.clearForLoad(book))
        observeOpenStage("loading_overlay_show_started")
        send(.showLoading(book))
        observeOpenStage("loading_overlay_show_completed")
        observeOpenStage("reader_load_task_scheduled")
        loadTask = Task { [weak self] in
            defer {
                prepared.cancel()
                if let self, self.loadGeneration == generation { self.preparedRead = nil }
            }
            guard !Task.isCancelled, let self else { return }
            observeOpenStage("reader_load_task_started")
            do {
                var next = arrivals.makeAsyncIterator()
                let first = await next.next()
                observeOpenStage(first.map {
                    if case .chapter(let prepared) = $0 {
                        return prepared == nil ? "first_arrival_projection_miss" : "first_arrival_projection"
                    }
                    return "first_arrival_catalog"
                } ?? "first_arrival_end")
                guard isActiveLoad(generation, bookID: book.id) else { return }
                if case .chapter(let prepared?) = first {
                    guard isActiveLoad(generation, bookID: book.id) else { return }
                    activePreparedChapter = prepared
                    selectedChapter = prepared.chapterOrdinal
                    send(.chapterCount(prepared.chapterCount))
                    LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
                    await textPresentation.restoreSelectedChapter(bookID: book.id)
                    guard isActiveLoad(generation, bookID: book.id) else { return }
                    presentLoadedChapter(bookID: book.id, onControlsResolved: startCatalog)
                } else {
                    startCatalog()
                }
                let cachedPayload: EbookFulltext?
                if case .catalog(let payload) = first { cachedPayload = payload }
                else { cachedPayload = await catalogTask.value }
                guard isActiveLoad(generation, bookID: book.id) else { return }
                let payload: EbookFulltext
                if let cachedPayload {
                    LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
                    payload = cachedPayload
                } else {
                    LatencyObservationStore.shared.classifyCache(.cold, for: journeyID)
                    let fileURL = try await library.openBookFileAsync(id: book.id)
                    guard self.isActiveLoad(generation, bookID: book.id) else { return }
                    if book.fileType == .pdf {
                        pendingPDFPageJourneyID = journeyID
                        guard let wasNormalized = await textPresentation.showPDF(fileURL) else { return }
                        guard self.isActiveLoad(generation, bookID: book.id) else { return }
                        observation.recordFirstPDFPage(wasNormalized: wasNormalized)
                        self.send(.hideLoading)
                        observation.recordControlsUsable()
                        return
                    }
                    payload = try await MacEpubParser.parse(at: fileURL, bookId: book.id)
                }
                guard self.isActiveLoad(generation, bookID: book.id) else { return }
                // A validated disk payload is already durable; do not reencode it on MainActor.
                if cachedPayload == nil {
                    let writer = preparedFulltextWriter
                    await Task.detached(priority: .utility) { writer(payload, book.id) }.value
                    guard self.isActiveLoad(generation, bookID: book.id) else { return }
                }
                LocalFulltextCache.recordWarmOpen(bookId: book.id)
                let prepared = activePreparedChapter
                let catalogMatches = prepared?.catalogChapters.map { catalog in
                    catalog.count == payload.chapters.count && zip(catalog, payload.chapters).allSatisfy { pair in
                        pair.0.index == pair.1.index && pair.0.name == pair.1.name
                            && pair.0.contentKind == pair.1.contentKind
                    }
                } ?? true
                let alreadyPresented = prepared.map {
                    $0.chapterCount == payload.chapters.count && $0.title == payload.bookTitle
                        && $0.author == payload.bookAuthor && $0.toc == payload.toc
                        && payload.chapters[safe: $0.chapterOrdinal] == $0.chapter
                } == true && catalogMatches
                if prepared != nil, !alreadyPresented {
                    presentationGeneration = UUID()
                    isRestoringInitialPosition = false
                    hasRestoredInitialPosition = false
                }
                fulltext = payload
                activePreparedChapter = nil
                send(.chapterCount(payload.chapters.count))
                send(.reloadContents)
                if alreadyPresented {
                    send(.selectCurrentContents)
                    prepareChapterProjection(bookID: book.id, ordinal: selectedChapter)
                    if hasRestoredInitialPosition, !isRestoringInitialPosition {
                        observation.recordControlsUsable()
                    }
                    return
                }
                if prepared != nil { hasRestoredInitialPosition = false }
                if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: book.id) {
                    selectedChapter = entry.chapterIndex
                } else {
                    let firstReadableChapter = payload.chapters.firstIndex {
                        $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80
                    } ?? 0
                    selectedChapter = min(max(selectedChapter, firstReadableChapter), max(0, payload.chapters.count - 1))
                }
                selectedChapter = min(max(selectedChapter, 0), max(0, payload.chapters.count - 1))
                if let row = self.tocRows.firstIndex(where: { $0.chapterIndex == self.selectedChapter }) {
                    send(.selectRow(row))
                }
                await textPresentation.restoreSelectedChapter(bookID: book.id)
                guard self.isActiveLoad(generation, bookID: book.id) else { return }
                presentLoadedChapter(bookID: book.id)
            } catch {
                guard self.isActiveLoad(generation, bookID: book.id) else { return }
                send(.failure(error))
            }
        }
    }

    private func presentLoadedChapter(bookID: String, onControlsResolved: (() -> Void)? = nil) {
        observeOpenStage("chapter_presentation_started")
        textPresentation.showChapter(selectedChapter)
        observeOpenStage("chapter_render_layout_completed")
        let generation = loadGeneration
        textPresentation.restoreReadingProgressIfNeeded(bookId: bookID) { [weak self] in
            guard let self, self.isActiveLoad(generation, bookID: bookID) else { return }
            self.observeOpenStage("saved_position_layout_committed")
            self.observation.recordReadableContent()
            self.send(.hideLoading)
            if self.fulltext != nil {
                self.observation.recordControlsUsable()
                onControlsResolved?()
            } else {
                self.recordPreparedControlsUsable(bookID: bookID, generation: generation,
                                                  onResolved: onControlsResolved)
            }
        }
    }

    private func recordPreparedControlsUsable(bookID: String, generation: UUID,
                                              onResolved: (() -> Void)?) {
        guard let snapshot = activePreparedChapter,
              snapshot.catalogChapters?.count == snapshot.chapterCount,
              let source = LocalFulltextCache.storageURL(bookId: bookID) else {
            onResolved?()
            return
        }
        observeOpenStage("prepared_controls_source_check_started")
        let matches = PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: source)
        guard isActiveLoad(generation, bookID: bookID) else { onResolved?(); return }
        observeOpenStage("prepared_controls_source_check_completed")
        if matches { observation.recordControlsUsable() }
        onResolved?()
    }

    func prepareChapterProjection(bookID: String, ordinal: Int) {
        guard fulltext?.chapters.indices.contains(ordinal) == true,
              lastPreparedChapterOrdinal != ordinal,
              let source = LocalFulltextCache.storageURL(bookId: bookID) else { return }
        lastPreparedChapterOrdinal = ordinal
        let store = preparedChapterStore
        Task(priority: .utility) { try? await store.write(bookID: bookID, chapterOrdinal: ordinal, fulltextURL: source) }
    }

}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
#endif
