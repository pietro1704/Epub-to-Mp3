#if os(macOS) && !targetEnvironment(simulator)
import AppKit
import PDFKit

enum MacReaderPreparedLoadEvent: Sendable {
    case catalog(EbookFulltext?)
    case chapter(PreparedReaderChapterStore.Snapshot?)
}

@MainActor
final class MacReaderPreparedRead {
    let arrivals: AsyncStream<MacReaderPreparedLoadEvent>
    let catalogTask: Task<EbookFulltext?, Never>
    private let chapterTask: Task<Void, Never>
    private let publisher: AsyncStream<MacReaderPreparedLoadEvent>.Continuation
    private let catalogStartSignal: AsyncStream<Void>.Continuation
    private var hasStartedCatalog = false

    init(bookID: String, reader: @escaping @Sendable (String) async -> EbookFulltext?,
         store: PreparedReaderChapterStore, observe: (@Sendable (String, UInt64) -> Void)?) {
        observe?("reader_progress_read_started", DispatchTime.now().uptimeNanoseconds)
        let progress = ReaderProgressStore.read(bookId: bookID)
        observe?("reader_progress_read_completed", DispatchTime.now().uptimeNanoseconds)
        let source = LocalFulltextCache.storageURL(bookId: bookID)
        observe?("fulltext_url_resolved", DispatchTime.now().uptimeNanoseconds)
        var continuation: AsyncStream<MacReaderPreparedLoadEvent>.Continuation!
        arrivals = AsyncStream<MacReaderPreparedLoadEvent> { continuation = $0 }
        let publisher = continuation!
        self.publisher = publisher
        var catalogStartContinuation: AsyncStream<Void>.Continuation!
        let catalogStart = AsyncStream<Void> { catalogStartContinuation = $0 }
        let catalogStartSignal = catalogStartContinuation!
        self.catalogStartSignal = catalogStartSignal
        catalogTask = Task.detached(priority: .utility) { () -> EbookFulltext? in
            var start = catalogStart.makeAsyncIterator()
            guard await start.next() != nil else { return nil }
            observe?("catalog_read_started", DispatchTime.now().uptimeNanoseconds)
            let payload = await reader(bookID)
            observe?("catalog_read_completed", DispatchTime.now().uptimeNanoseconds)
            publisher.yield(.catalog(payload))
            return payload
        }
        let chapterOrdinal = progress?.chapterIndex
        chapterTask = Task.detached(priority: .userInitiated) {
            let prepared: PreparedReaderChapterStore.Snapshot?
            if let chapterOrdinal, let source {
                observe?("projection_read_started", DispatchTime.now().uptimeNanoseconds)
                prepared = await store.read(bookID: bookID,
                    chapterOrdinal: chapterOrdinal, fulltextURL: source)
                observe?("projection_read_completed", DispatchTime.now().uptimeNanoseconds)
            } else {
                prepared = nil
                observe?("projection_read_skipped", DispatchTime.now().uptimeNanoseconds)
            }
            publisher.yield(.chapter(prepared))
        }
    }

    func startCatalog() {
        guard !hasStartedCatalog else { return }
        hasStartedCatalog = true
        catalogStartSignal.yield(())
    }

    func cancel() {
        publisher.finish()
        catalogStartSignal.finish()
        chapterTask.cancel()
        catalogTask.cancel()
    }

    deinit {
        publisher.finish()
        catalogStartSignal.finish()
        chapterTask.cancel()
        catalogTask.cancel()
    }
}
#endif
