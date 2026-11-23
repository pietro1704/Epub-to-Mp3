import Foundation

/// Owns source routing and the lifetime of a book open. Native presenters
/// supply their existing preparation order and apply checked arrivals.
@MainActor
final class ReaderOpenSession {
    @MainActor
    struct Attempt {
        let book: BookEntity
        let generation: UUID
        let journeyID: UUID
        private let isCurrent: () -> Bool

        fileprivate init(book: BookEntity, generation: UUID, journeyID: UUID, isCurrent: @escaping () -> Bool) {
            self.book = book
            self.generation = generation
            self.journeyID = journeyID
            self.isCurrent = isCurrent
        }

        func check() throws {
            guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        }

        func read<Value>(_ work: () async throws -> Value) async throws -> Value {
            try check()
            let value = try await work()
            try check()
            return value
        }

        func classify(_ cache: LatencyObservation.CacheClass) {
            LatencyObservationStore.shared.classifyCache(cache, for: journeyID)
        }
    }

    enum Arrival {
        case pdf(URL)
        case text(EbookFulltext, fromDisk: Bool)
    }

    private let document: ReaderDocument
    private var task: Task<Void, Never>?
    private var activeGeneration: UUID?

    init(document: ReaderDocument) { self.document = document }

    deinit { task?.cancel() }

    func cancel() {
        activeGeneration = nil
        task?.cancel()
        document.openJourney.cancelActiveBookOpenJourney()
    }

    func waitForCompletion() async { await task?.value }

    func begin(book: BookEntity, generation: UUID, isCurrent: @escaping () -> Bool) -> Attempt {
        task = nil
        activeGeneration = generation
        let journeyID = document.openJourney.begin(for: book)
        return Attempt(book: book, generation: generation, journeyID: journeyID) { [weak self] in
            self?.activeGeneration == generation && isCurrent()
        }
    }

    func warmPayload(for attempt: Attempt) -> EbookFulltext? {
        guard attempt.book.fileType != .pdf,
              let payload = LocalFulltextCache.inMemoryPayload(bookId: attempt.book.id),
              !payload.chapters.isEmpty else { return nil }
        attempt.classify(.inMemoryWarm)
        return payload
    }

    func schedule(_ attempt: Attempt, run: @escaping (Attempt) async throws -> Void,
                  failure: @escaping (Error) -> Void) {
        task = Task {
            do {
                try attempt.check()
                try await run(attempt)
            } catch {
                guard (try? attempt.check()) != nil else { return }
                failure(error)
            }
        }
    }

    func resolve(_ attempt: Attempt, cached: EbookFulltext?,
                 openSource: (String) async throws -> URL,
                 parseText: (URL, Attempt) async throws -> EbookFulltext) async throws -> Arrival {
        try attempt.check()
        if let cached, attempt.book.fileType != .pdf {
            attempt.classify(.preparedDisk)
            return .text(cached, fromDisk: true)
        }
        attempt.classify(.cold)
        let url = try await attempt.read { try await openSource(attempt.book.id) }
        if attempt.book.fileType == .pdf {
            document.openJourney.pendingPDFPageJourneyID = attempt.journeyID
            return .pdf(url)
        }
        let payload = try await attempt.read { try await parseText(url, attempt) }
        return .text(payload, fromDisk: false)
    }
}
