#if os(iOS)
import UIKit

/// Owns a book-open attempt and its cancellation; it emits UI work only after
/// validating the current document generation at each suspension boundary.
@MainActor
final class ReaderBookLoadSession {
    typealias PreparedFulltextWriter = @Sendable (EbookFulltext, String, Int?, PreparedReaderChapterStore) async -> Void
    enum Event {
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
    private let opening: ReaderOpenSession

    init(document: ReaderBookDocument, settings: AppSettings, renderer: PreparedChapterRenderer,
         store: PreparedReaderChapterStore, preparedPresentation: ReaderPreparedPresentation,
         readFulltext: @escaping @Sendable (String) async -> EbookFulltext?,
         writeFulltext: PreparedFulltextWriter? = nil,
         openBook: @escaping (String) async throws -> URL,
         stageObserver: (@Sendable (String, UInt64) -> Void)?, send: @escaping (Event) -> Void) {
        self.document = document
        opening = ReaderOpenSession(document: document)
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

    func cancel() {
        opening.cancel()
        preparedPresentation.restoration.cancel()
        document.loadGenerationID = nil
        document.activeLoadingID = nil
    }

    func waitForCompletion() async { await opening.waitForCompletion() }

    func loadBook() {
        LocalFulltextCache.cancelPrewarming()
        opening.cancel()
        preparedPresentation.restoration.cancel()
        let loadingBookID = document.book.id
        let loadingID = UUID()
        document.activeLoadingID = loadingID
        document.loadGenerationID = loadingID
        document.pendingLoadingCompletionID = nil
        document.hasRestoredInitialPosition = false
        document.activePreparedChapter = nil
        document.pendingProjectionAnchor = nil
        document.presentedProjectionLoadingID = nil
        document.lastPreparedChapterOrdinal = nil
        let attempt = opening.begin(book: document.book, generation: loadingID) { [weak document] in
            document?.isCurrentLoad(loadingID, bookID: loadingBookID) == true
        }
        observeOpenStage("reader_open_requested")

        // Memory-ready text stays synchronous. A disk-prepared rendering is
        // restored without reopening the source or running the HTML importer.
        if let warmPayload = opening.warmPayload(for: attempt) {
            document.registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: loadingBookID)
            if let index = preparedPresentation.preparedChapterIndex(in: warmPayload),
               let source = LocalFulltextCache.storageURL(bookId: loadingBookID) {
                document.lastPreparedChapterOrdinal = index
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
                    textSettings: ReaderTextSettings(settings: settings),
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
            opening.schedule(attempt) { [weak self] attempt in
                guard let self else { return }
                let preparedRendering = try await attempt.read {
                    await self.preparedPresentation.restorePreparedChapter(in: warmPayload)
                }
                preparedPresentation.displayPreparedPayload(warmPayload, loadingID: loadingID,
                                       preparedRendering: preparedRendering)
            } failure: { [weak self] error in self?.send(.failure(error.localizedDescription)) }
            return
        }

        send(.showLoading)
        if ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            attempt.classify(.cold)
            send(.loadFixture)
            return
        }
        document.registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: loadingBookID)
        preparedPresentation.restoration.schedule(loadingID: loadingID, bookID: loadingBookID)
        opening.schedule(attempt) { [weak self] attempt in
            guard let self else { return }
            observeOpenStage("reader_load_task_started")
            observeOpenStage("projection_read_started")
            try await attempt.read {
                await self.preparedPresentation.restoration.waitForPresentation(loadingID: loadingID, bookID: loadingBookID)
                self.observeOpenStage("projection_read_completed")
            }
            observeOpenStage("prepared_fulltext_read_started")
            let cached = try await attempt.read {
                let payload = await self.preparedFulltextReader(loadingBookID)
                self.observeOpenStage("prepared_fulltext_read_completed")
                return payload
            }
            let cachedNeedsTitleRepair = cached?.chapters.contains(where: { $0.hasGeneratedName }) == true
            let cachedHasReadableContent = cached?.chapters.contains(where: { $0.hasReadableContent }) == true
            let titleRepairKey = "reader.titleRepairAttempted.\(loadingBookID)"
            let shouldRepairCachedTitles = cachedNeedsTitleRepair && !UserDefaults.standard.bool(forKey: titleRepairKey)
            let validCache = !shouldRepairCachedTitles && cachedHasReadableContent ? cached : nil
            let arrival = try await opening.resolve(attempt, cached: validCache, openSource: openBook) { url, attempt in
                let payload = try await attempt.read {
                    await EpubFallbackParser.parseAsync(url: url, bookId: loadingBookID)
                }
                if self.document.registeredFontURLs.isEmpty {
                    let fonts = try await attempt.read {
                        await Task.detached(priority: .userInitiated) {
                            EpubFontManager.registerFonts(from: url, bookID: loadingBookID)
                        }.value
                    }
                    self.document.registeredFontURLs = fonts
                }
                return payload
            }
            switch arrival {
            case .pdf(let url):
                send(.showPDF(url))
                try attempt.check()
                send(.hideLoading)
            case .text(let payload, _):
                try await publish(payload, attempt: attempt, repairsTitle: cachedNeedsTitleRepair, titleRepairKey: titleRepairKey)
            }
        } failure: { [weak self] error in self?.send(.failure(error.localizedDescription)) }
        observeOpenStage("reader_load_task_scheduled")
    }

    private func publish(_ payload: EbookFulltext, attempt: ReaderOpenSession.Attempt,
                         repairsTitle: Bool, titleRepairKey: String) async throws {
        let loadingID = attempt.generation
        let bookID = attempt.book.id
        if preparedPresentation.attachHydratedCatalog(payload, loadingID: loadingID) { return }
        if document.registeredFontURLs.isEmpty {
            document.registeredFontURLs = EpubFontManager.registerCachedFonts(bookID: bookID)
        }
        let preparedIndex = preparedPresentation.preparedChapterIndex(in: payload)
        let preparedStore = preparedChapterStore
        let writeFulltext = preparedFulltextWriter
        Task.detached(priority: .utility) {
            await writeFulltext(payload, bookID, preparedIndex, preparedStore)
        }
        if repairsTitle { UserDefaults.standard.set(true, forKey: titleRepairKey) }
        let preparedRendering = try await attempt.read {
            await preparedPresentation.restorePreparedChapter(in: payload)
        }
        document.lastPreparedChapterOrdinal = preparedIndex
        observeOpenStage("prepared_payload_display_started")
        preparedPresentation.displayPreparedPayload(payload, loadingID: loadingID, preparedRendering: preparedRendering)
        observeOpenStage("prepared_payload_display_completed")
    }

}
#endif
