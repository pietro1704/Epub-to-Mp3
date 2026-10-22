#if os(iOS)
import UIKit

struct PreparedProjectionRead: Sendable {
    let snapshot: PreparedReaderChapterStore.Snapshot
    let progress: ReaderProgressStore.Entry
}

struct PreparedProjectionRestoration: Sendable {
    let projection: PreparedProjectionRead
    let style: PreparedChapterRendererStyle
    let renderer: PreparedChapterRendererRestoration?
}

final class PreparedProjectionRestorationSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var restoration: PreparedProjectionRestoration?

    func store(_ restoration: PreparedProjectionRestoration?) {
        lock.lock()
        self.restoration = restoration
        lock.unlock()
    }

    func take() -> PreparedProjectionRestoration? {
        lock.lock()
        defer { lock.unlock() }
        let value = restoration
        restoration = nil
        return value
    }
}


@MainActor
final class ReaderPreparedRestoration {
    private let document: ReaderBookDocument
    private let settings: AppSettings
    private let preparedRenderer: PreparedChapterRenderer
    private let preparedChapterStore: PreparedReaderChapterStore
    private let openStageObserver: (@Sendable (String, UInt64) -> Void)?
    private let present: @MainActor (PreparedProjectionRestoration?, UUID, String) async -> Void
    private var preparedProjectionReadTask: Task<PreparedProjectionRead?, Never>?
    private var preparedProjectionRestoreTask: Task<PreparedProjectionRestoration?, Never>?
    private var preparedProjectionPresentationTask: Task<Void, Never>?
    let slot = PreparedProjectionRestorationSlot()

    init(document: ReaderBookDocument, settings: AppSettings, renderer: PreparedChapterRenderer,
         store: PreparedReaderChapterStore, stageObserver: (@Sendable (String, UInt64) -> Void)?,
         present: @escaping @MainActor (PreparedProjectionRestoration?, UUID, String) async -> Void) {
        self.document = document
        self.settings = settings
        preparedRenderer = renderer
        preparedChapterStore = store
        openStageObserver = stageObserver
        self.present = present
    }

    func cancel() {
        preparedProjectionReadTask?.cancel()
        preparedProjectionReadTask = nil
        preparedProjectionRestoreTask?.cancel()
        preparedProjectionRestoreTask = nil
        preparedProjectionPresentationTask?.cancel()
        preparedProjectionPresentationTask = nil
        slot.store(nil)
    }

    deinit {
        preparedProjectionReadTask?.cancel()
        preparedProjectionRestoreTask?.cancel()
        preparedProjectionPresentationTask?.cancel()
    }

    func schedule(loadingID: UUID, bookID loadingBookID: String) {
        let fontDirectoryURL = document.registeredFontURLs.first?.deletingLastPathComponent()
        let rendererStyle = preparedRenderer.styleSnapshot(
            settings: settings,
            fontDirectoryURL: fontDirectoryURL
        )
        let rendererWorker = preparedRenderer.backgroundRestoreWorker()
        preparedProjectionReadTask = prepareProjectionRead(bookID: loadingBookID)
        if let projectionReadTask = preparedProjectionReadTask {
            let stageObserver = openStageObserver
            let restorationSlot = slot
            preparedProjectionRestoreTask = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled,
                      let projection = await projectionReadTask.value,
                      !Task.isCancelled else { return nil }
                let renderer = await rendererWorker.restore(
                    bookID: loadingBookID,
                    chapterIndex: projection.snapshot.chapterOrdinal,
                    chapter: projection.snapshot.chapter,
                    style: rendererStyle,
                    stageObserver: stageObserver
                )
                guard !Task.isCancelled else { return nil }
                let restoration = PreparedProjectionRestoration(
                    projection: projection,
                    style: rendererStyle,
                    renderer: renderer
                )
                restorationSlot.store(restoration)
                return restoration
            }
            if let projectionRestoreTask = preparedProjectionRestoreTask {
                preparedProjectionPresentationTask = Task.detached(priority: .userInitiated) { [weak self] in
                    let restoration = await projectionRestoreTask.value
                    guard !Task.isCancelled else { return }
                    await self?.present(restoration, loadingID, loadingBookID)
                }
            }
        }
    }

    func waitForPresentation(loadingID: UUID, bookID: String) async {
        if let preparedProjectionPresentationTask {
            await preparedProjectionPresentationTask.value
        } else {
            await present(nil, loadingID, bookID)
        }
    }

    private func prepareProjectionRead(bookID: String) -> Task<PreparedProjectionRead?, Never>? {
        guard document.book.fileType != .pdf,
              let progress = ReaderProgressStore.read(bookId: bookID),
              let fulltextURL = LocalFulltextCache.storageURL(bookId: bookID) else { return nil }
        let store = preparedChapterStore
        let stageObserver = openStageObserver
        observeOpenStage("projection_read_scheduled")
        return Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let snapshot = await store.read(
                    bookID: bookID,
                    chapterOrdinal: progress.chapterIndex,
                    fulltextURL: fulltextURL
                  ),
                  snapshot.catalogChapters?.count == snapshot.chapterCount,
                  snapshot.chapter.hasReadableContent,
                  PreparedReaderChapterStore.sourceMatches(snapshot, fulltextURL: fulltextURL),
                  !Task.isCancelled else { return nil }
            let validatedAt = DispatchTime.now().uptimeNanoseconds
            stageObserver?("projection_snapshot_validated", validatedAt)
            return PreparedProjectionRead(snapshot: snapshot, progress: progress)
        }
    }

    private func observeOpenStage(_ name: String) {
        openStageObserver?(name, DispatchTime.now().uptimeNanoseconds)
    }
}
#endif
