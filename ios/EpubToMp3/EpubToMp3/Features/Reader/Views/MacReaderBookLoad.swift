#if os(macOS)
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
    private let location: ReaderLocation
    private let document: MacReaderDocument
    private let library: LibraryStore
    private let settings: AppSettings
    private let preparedRenderer: PreparedChapterRenderer
    private let preparedChapterStore: PreparedReaderChapterStore
    private let preparedFulltextReader: @Sendable (String) async -> EbookFulltext?
    private let preparedFulltextWriter: @Sendable (EbookFulltext, String) -> Void
    private let textPresentation: MacReaderTextPresentation
    private let observation: ReaderOpenJourney
    private let openStageObserver: (@Sendable (String, UInt64) -> Void)?
    private let send: (Event) -> Void
    private let opening: ReaderOpenSession
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

    init(document: MacReaderDocument, library: LibraryStore, settings: AppSettings, location: ReaderLocation,
         renderer: PreparedChapterRenderer, store: PreparedReaderChapterStore,
         readFulltext: @escaping @Sendable (String) async -> EbookFulltext?,
         writeFulltext: @escaping @Sendable (EbookFulltext, String) -> Void,
         textPresentation: MacReaderTextPresentation, observation: ReaderOpenJourney,
         stageObserver: (@Sendable (String, UInt64) -> Void)?, send: @escaping (Event) -> Void) {
        self.location = location
        self.document = document
        opening = ReaderOpenSession(document: document)
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

    private func observeOpenStage(_ name: String) { openStageObserver?(name, DispatchTime.now().uptimeNanoseconds) }
    private func isActiveLoad(_ id: UUID, bookID: String) -> Bool {
        document.isActiveLoad(id, bookID: bookID) && location.readingBookID == bookID
    }

    func cancel() {
        opening.cancel()
        preparedRead?.cancel()
        preparedRead = nil
        loadGeneration = UUID()
        presentationGeneration = UUID()
    }

    func loadCurrentBook() {
        LocalFulltextCache.cancelPrewarming()
        cancel()
        let generation = loadGeneration
        isRestoringInitialPosition = false
        pendingAppearanceRefresh = false
        activePreparedChapter = nil
        lastPreparedChapterOrdinal = nil
        document.registeredFontURLs = []
        send(.resetTextSurface)
        let id = location.readingBookID
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
        document.registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: book.id)
        let attempt = opening.begin(book: book, generation: generation) { [weak document, weak location] in
            document?.isActiveLoad(generation, bookID: book.id) == true && location?.readingBookID == book.id
        }
        observeOpenStage("journey_started")
        // Process-warm reader opens must not clear the visible chapter or
        // show the loading cover. The last two prepared books are retained
        // in memory precisely so this route can paint immediately.
        if let warmPayload = opening.warmPayload(for: attempt) {
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
                   textSettings: ReaderTextSettings(settings: settings), fontDirectoryURL: document.fontDirectoryURL) != nil {
                presentLoadedChapter(bookID: book.id)
            } else {
                send(.showLoading(book))
                opening.schedule(attempt) { [weak self] attempt in
                    guard let self else { return }
                    try await attempt.read { await self.textPresentation.restoreSelectedChapter(bookID: book.id) }
                    presentLoadedChapter(bookID: book.id)
                } failure: { [weak self] error in self?.send(.failure(error)) }
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
        opening.schedule(attempt) { [weak self] attempt in
            defer {
                prepared.cancel()
                if let self, self.loadGeneration == generation { self.preparedRead = nil }
            }
            guard let self else { return }
            observeOpenStage("reader_load_task_started")
            var next = arrivals.makeAsyncIterator()
            let first = try await attempt.read { await next.next() }
            observeOpenStage(first.map {
                if case .chapter(let prepared) = $0 {
                    return prepared == nil ? "first_arrival_projection_miss" : "first_arrival_projection"
                }
                return "first_arrival_catalog"
            } ?? "first_arrival_end")
            if book.fileType != .pdf, case .chapter(let prepared?) = first {
                activePreparedChapter = prepared
                selectedChapter = prepared.chapterOrdinal
                send(.chapterCount(prepared.chapterCount))
                attempt.classify(.preparedDisk)
                try await attempt.read { await self.textPresentation.restoreSelectedChapter(bookID: book.id) }
                presentLoadedChapter(bookID: book.id, onControlsResolved: startCatalog)
            } else {
                startCatalog()
            }
            let cachedPayload: EbookFulltext?
            if case .catalog(let payload) = first { cachedPayload = payload }
            else { cachedPayload = try await attempt.read { await catalogTask.value } }
            let arrival = try await opening.resolve(attempt, cached: cachedPayload,
                openSource: { try await self.library.openBookFileAsync(id: $0) }) { url, attempt in
                    let fonts = try await attempt.read {
                        await Task.detached(priority: .utility) {
                            EpubFontManager.registerFonts(from: url, bookID: book.id)
                        }.value
                    }
                    self.document.registeredFontURLs = fonts
                    return try await MacEpubParser.parse(at: url, bookId: book.id)
                }
            switch arrival {
            case .pdf(let url):
                guard let wasNormalized = try await attempt.read({ await self.textPresentation.showPDF(url) }) else { return }
                observation.recordFirstPDFPage(wasNormalized: wasNormalized)
                send(.hideLoading)
                try attempt.check()
                observation.recordControlsUsable()
            case .text(let payload, let fromDisk):
                try await publish(payload, fromDisk: fromDisk, attempt: attempt)
            }
        } failure: { [weak self] error in self?.send(.failure(error)) }
    }

    private func publish(_ payload: EbookFulltext, fromDisk: Bool, attempt: ReaderOpenSession.Attempt) async throws {
        let bookID = attempt.book.id
        // A disk payload is already durable.
        if !fromDisk {
            let writer = preparedFulltextWriter
            try await attempt.read { await Task.detached(priority: .utility) { writer(payload, bookID) }.value }
        }
        LocalFulltextCache.recordWarmOpen(bookId: bookID)
        let prepared = activePreparedChapter
        let alreadyPresented = prepared?.matchesCatalog(payload, bookID: bookID, chapterOrdinal: selectedChapter) == true
        if prepared != nil, !alreadyPresented {
            presentationGeneration = UUID()
            isRestoringInitialPosition = false
            hasRestoredInitialPosition = false
        }
        fulltext = payload
        activePreparedChapter = nil
        send(.chapterCount(payload.chapters.count))
        try attempt.check()
        send(.reloadContents)
        try attempt.check()
        if alreadyPresented {
            send(.selectCurrentContents)
            try attempt.check()
            prepareChapterProjection(bookID: bookID, ordinal: selectedChapter)
            if hasRestoredInitialPosition, !isRestoringInitialPosition {
                observation.recordControlsUsable()
            }
            return
        }
        if !hasRestoredInitialPosition, let entry = ReaderProgressStore.read(bookId: bookID) {
            selectedChapter = entry.chapterIndex
        } else {
            let firstReadableChapter = payload.chapters.firstIndex {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80
            } ?? 0
            selectedChapter = min(max(selectedChapter, firstReadableChapter), max(0, payload.chapters.count - 1))
        }
        selectedChapter = min(max(selectedChapter, 0), max(0, payload.chapters.count - 1))
        if let row = tocRows.firstIndex(where: { $0.chapterIndex == selectedChapter }) {
            send(.selectRow(row))
        }
        try await attempt.read { await textPresentation.restoreSelectedChapter(bookID: bookID) }
        presentLoadedChapter(bookID: bookID)
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
