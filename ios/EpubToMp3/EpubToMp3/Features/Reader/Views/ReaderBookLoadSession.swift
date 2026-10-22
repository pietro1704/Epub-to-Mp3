#if os(iOS)
import UIKit

/// Owns a book-open attempt and its cancellation; it emits UI work only after
/// validating the current document generation at each suspension boundary.
@MainActor
final class ReaderBookLoadSession {
    typealias PreparedFulltextWriter = @Sendable (EbookFulltext, String, Int?, PreparedReaderChapterStore) async -> Void
    enum Event {
        case cancelJourney
        case showLoading
        case hideLoading
        case loadFixture
        case showPDF(URL)
        case failure(String)
    }

    private let document: ReaderBookDocument
    private let settings: AppSettings
    private let preparedRenderer: PreparedChapterRenderer
    private let preparedChapterStore: PreparedReaderChapterStore
    private let preparedFulltextReader: @Sendable (String) async -> EbookFulltext?
    private let preparedFulltextWriter: PreparedFulltextWriter
    private let openBook: (String) async throws -> URL
    private let preparedPresentation: ReaderPreparedPresentation
    private let observeOpenStage: (String) -> Void
    private let send: (Event) -> Void
    private var loadTask: Task<Void, Never>?

    init(document: ReaderBookDocument, settings: AppSettings, renderer: PreparedChapterRenderer,
         store: PreparedReaderChapterStore, preparedPresentation: ReaderPreparedPresentation,
         readFulltext: @escaping @Sendable (String) async -> EbookFulltext?,
         writeFulltext: PreparedFulltextWriter? = nil,
         openBook: @escaping (String) async throws -> URL,
         stageObserver: (@Sendable (String, UInt64) -> Void)?, send: @escaping (Event) -> Void) {
        self.document = document
        self.settings = settings
        preparedRenderer = renderer
        preparedChapterStore = store
        self.preparedPresentation = preparedPresentation
        preparedFulltextReader = readFulltext
        preparedFulltextWriter = writeFulltext ?? { payload, bookID, chapterOrdinal, store in
            if let chapterOrdinal {
                await LocalFulltextCache.saveAndPrepareReaderChapter(
                    payload, bookId: bookID, chapterOrdinal: chapterOrdinal, store: store)
            } else {
                LocalFulltextCache.save(payload, bookId: bookID)
            }
        }
        self.openBook = openBook
        self.send = send
        observeOpenStage = { stageObserver?($0, DispatchTime.now().uptimeNanoseconds) }
    }

    deinit { loadTask?.cancel() }

    func cancel() {
        loadTask?.cancel()
        preparedPresentation.restoration.cancel()
        document.loadGenerationID = nil
        document.activeLoadingID = nil
    }

    func waitForCompletion() async { await loadTask?.value }

    private func isCurrentLoad(_ loadingID: UUID, bookID: String) -> Bool {
        document.isCurrentLoad(loadingID, bookID: bookID)
    }

    func loadBook() {
        LocalFulltextCache.cancelPrewarming()
        loadTask?.cancel()
        loadTask = nil
        preparedPresentation.restoration.cancel()
        send(.cancelJourney)
        let loadingBookID = document.book.id
        let loadingID = UUID()
        document.activeLoadingID = loadingID
        document.loadGenerationID = loadingID
        document.pendingLoadingCompletionID = nil
        document.hasRestoredInitialPosition = false
        document.activePreparedChapter = nil
        document.pendingProjectionAnchor = nil
        document.presentedProjectionLoadingID = nil
        document.lastPreparedProjectionOrdinal = nil
        let journeyID = LatencyObservationStore.shared.beginBookOpen(
            documentKind: document.book.fileType == .pdf ? .selectableTextPDF : .epub
        )
        document.activeBookOpenJourneyID = journeyID
        observeOpenStage("reader_open_requested")

        // Memory-ready text stays synchronous. A disk-prepared rendering is
        // restored without reopening the source or running the HTML importer.
        if let warmPayload = LocalFulltextCache.inMemoryPayload(bookId: loadingBookID),
           !warmPayload.chapters.isEmpty {
            LatencyObservationStore.shared.classifyCache(.inMemoryWarm, for: journeyID)
            document.registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: loadingBookID)
            if let index = preparedPresentation.preparedChapterIndex(in: warmPayload),
               let source = LocalFulltextCache.storageURL(bookId: loadingBookID) {
                document.lastPreparedProjectionOrdinal = index
                let store = preparedChapterStore
                Task.detached(priority: .utility) {
                    try? await store.write(bookID: loadingBookID, chapterOrdinal: index, fulltextURL: source)
                }
            }
            if let index = preparedPresentation.preparedChapterIndex(in: warmPayload) {
                let chapter = warmPayload.chapters[index]
                let preparedRendering = preparedRenderer.cached(
                    bookID: loadingBookID,
                    chapterIndex: index,
                    chapter: chapter,
                    settings: settings,
                    fontDirectoryURL: document.registeredFontURLs.first?.deletingLastPathComponent()
                )
                if chapter.isImageOnly || chapter.html?.isEmpty != false
                    || preparedRendering != nil {
                    preparedPresentation.displayPreparedPayload(warmPayload, loadingID: loadingID,
                                           preparedRendering: preparedRendering)
                    return
                }
            }
            send(.showLoading)
            loadTask = Task { [weak self] in
                guard let self else { return }
                let preparedRendering = await preparedPresentation.restorePreparedChapter(in: warmPayload)
                guard !Task.isCancelled, isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                preparedPresentation.displayPreparedPayload(warmPayload, loadingID: loadingID,
                                       preparedRendering: preparedRendering)
            }
            return
        }

        send(.showLoading)
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            LatencyObservationStore.shared.classifyCache(.cold, for: journeyID)
            send(.loadFixture)
            return
        }
        document.registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: loadingBookID)
        preparedPresentation.restoration.schedule(loadingID: loadingID, bookID: loadingBookID)
        loadTask = Task { [weak self] in
            guard let self else { return }
            observeOpenStage("reader_load_task_started")
            do {
                observeOpenStage("projection_read_started")
                await preparedPresentation.restoration.waitForPresentation(loadingID: loadingID, bookID: loadingBookID)
                observeOpenStage("projection_read_completed")
                guard !Task.isCancelled, self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                observeOpenStage("prepared_fulltext_read_started")
                let cached = await preparedFulltextReader(loadingBookID)
                observeOpenStage("prepared_fulltext_read_completed")
                guard !Task.isCancelled, isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                let payload: EbookFulltext
                let cachedNeedsTitleRepair = cached?.chapters.contains(where: { $0.hasGeneratedName }) == true
                let cachedHasReadableContent = cached?.chapters.contains(where: { $0.hasReadableContent }) == true
                let titleRepairKey = "reader.titleRepairAttempted.\(document.book.id)"
                let shouldRepairCachedTitles = cachedNeedsTitleRepair
                    && !UserDefaults.standard.bool(forKey: titleRepairKey)
                if let cached, !shouldRepairCachedTitles, cachedHasReadableContent {
                    LatencyObservationStore.shared.classifyCache(.preparedDisk, for: journeyID)
                    payload = cached
                } else {
                    LatencyObservationStore.shared.classifyCache(.cold, for: journeyID)
                    let url = try await openBook(loadingBookID)
                    guard !Task.isCancelled, isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                    if document.book.fileType == .pdf {
                        document.pendingPDFPageJourneyID = journeyID
                        send(.showPDF(url))
                        guard self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                        send(.hideLoading)
                        return
                    }
                    payload = await EpubFallbackParser.parseAsync(url: url, bookId: loadingBookID)
                    guard !Task.isCancelled, self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                    if document.registeredFontURLs.isEmpty {
                        let fonts = await Task.detached(priority: .userInitiated) {
                            EpubFontManager.registerFonts(from: url, bookID: loadingBookID)
                        }.value
                        guard !Task.isCancelled, isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                        document.registeredFontURLs = fonts
                    }
                }
                guard !Task.isCancelled, self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                if preparedPresentation.attachHydratedCatalog(payload, loadingID: loadingID) { return }
                if document.registeredFontURLs.isEmpty {
                    document.registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: loadingBookID)
                }
                let preparedIndex = preparedPresentation.preparedChapterIndex(in: payload)
                let preparedStore = preparedChapterStore
                let writeFulltext = preparedFulltextWriter
                Task.detached(priority: .utility) {
                    await writeFulltext(payload, loadingBookID, preparedIndex, preparedStore)
                }
                if cachedNeedsTitleRepair {
                    UserDefaults.standard.set(true, forKey: titleRepairKey)
                }
                let preparedRendering = await preparedPresentation.restorePreparedChapter(in: payload)
                guard !Task.isCancelled, self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                document.lastPreparedProjectionOrdinal = preparedIndex
                observeOpenStage("prepared_payload_display_started")
                preparedPresentation.displayPreparedPayload(payload, loadingID: loadingID,
                                       preparedRendering: preparedRendering)
                observeOpenStage("prepared_payload_display_completed")
            } catch {
                guard !Task.isCancelled, self.isCurrentLoad(loadingID, bookID: loadingBookID) else { return }
                send(.failure(error.localizedDescription))
            }
        }
        observeOpenStage("reader_load_task_scheduled")
    }

}
#endif
