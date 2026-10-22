import Foundation
import Combine


/// Owns the user's personal book library. The library is **disk-first**
/// — every book is an EPUB the user picked themselves; the backend is
/// not the source of truth. We persist a small JSON index in
/// `UserDefaults` so the library survives reinstalls less than restarts;
/// for a real shipping app this would migrate to a SQLite store.
///
/// Imported books are copied into the app-owned library directory and
/// represented by a durable bookmark. The original picker URL is only
/// accessed during import or one-time migration of legacy entries.
///
/// Persistence target: the App Group suite (`group.com.pietrocode.epubtomp3`)
/// is used when available — this lets the WidgetKit extension (`EpubToMp3Widget`)
/// read the same `"library.books.v1"` key without IPC. Falls back to
/// `.standard` on simulators without a provisioned group and in unit tests.
final class LibraryStore: ObservableObject {
    private let indexPersistence: LibraryIndexPersistence
    private let importDirectory: URL?
    private var removalGenerations: [String: Int] = [:]

    @Published private(set) var books: [BookEntity] = []
    @Published private(set) var loadError: String?

    private let defaultsKey: String
    private let defaults: UserDefaults
    private let fileManager: FileManager

    /// App Group suite identifier — must match the entitlement and the
    /// widget provider's `appGroupID` constant.
    static let appGroupID = "group.com.pietrocode.epubtomp3"

    init(
        defaults: UserDefaults? = nil,
        defaultsKey: String = "library.books.v1",
        fileManager: FileManager = .default,
        importDirectory: URL? = nil,
        indexEncoder: @escaping @Sendable ([BookEntity]) throws -> Data = { try JSONEncoder().encode($0) }
    ) {
        // Prefer the App Group suite so the WidgetKit extension can
        // share the same UserDefaults store. Falls back to `.standard`
        // when the group container is not provisioned (simulator without
        // entitlements, unit tests).
        let resolvedDefaults: UserDefaults
        if let explicit = defaults {
            resolvedDefaults = explicit
        } else if let group = UserDefaults(suiteName: Self.appGroupID) {
            resolvedDefaults = group
        } else {
            resolvedDefaults = .standard
        }
        self.defaults = resolvedDefaults
        self.defaultsKey = defaultsKey
        self.fileManager = fileManager
        self.importDirectory = importDirectory
        self.indexPersistence = LibraryIndexPersistence(defaults: resolvedDefaults, key: defaultsKey,
                                                       encoder: indexEncoder)
        // UI tests install a deterministic fixture immediately after app
        // launch. Skip decoding the user's persisted library in that mode:
        // it can contain large cover payloads and makes launch timing and
        // accessibility tests depend on unrelated local state.
        if !ProcessInfo.processInfo.arguments.contains("-uiTestFixture") {
            // The persisted index is intentionally small; decode synchronously
            // during construction so a mutable ObservableObject is never sent
            // across an actor boundary while it is being initialized.
            loadSync()
        }
    }

    /// Synchronous on-actor load. Used by test/preview inits where the
    /// caller passed a specific `UserDefaults` and expects the books
    /// array to be hydrated before control returns.
    private func loadSync() {
        apply(LibraryIndexCodec.decode(data: defaults.data(forKey: defaultsKey)))
    }

    private func apply(_ outcome: LibraryIndexCodec.DecodeOutcome) {
        switch outcome {
        case .success(let (books, needsPersist)):
            self.books = books
            if needsPersist { persist() }
        case .failure(let error):
            self.loadError = error
        case .empty:
            break
        }
    }

    // MARK: - CRUD

    /// Import a new book from a file picker URL. The URL must be
    /// "fresh" — i.e. the caller already received it from a sandboxed
    /// `fileImporter`/`UIDocumentPickerViewController`. We:
    ///
    /// 1. Read enough of the file to compute a content hash (the id).
    /// 2. Copy the file into the app-owned library directory.
    /// 3. Persist a bookmark to that durable copy.
    /// 4. Best-effort parse title/author/cover from EPUB metadata.
    /// 5. De-dupe — if the same content hash is already in the library,
    ///    refresh its bookmark + filename and skip the rest.
    @discardableResult
    func importBook(from url: URL) throws -> BookEntity {
        // Compatibility for synchronous, non-batch callers. Batch UI imports use
        // importBooks(from:) so waiting for this serial worker never blocks UI.
        let prepared = try LibraryImportExecutor.performSync {
            try LibraryImportPreparation.prepare(from: url, fileManager: fileManager, importDirectory: importDirectory)
        }
        let baseline = books.first(where: { $0.id == prepared.book.id })
        let book = Self.mergeImport(prepared, baseline: baseline, into: &books)
        persist()
        // This legacy blocking API retains its immediate-reload contract.
        try flushPersistenceSync()
        return book
    }

    /// A batch performs one preparation at a time, then merges and persists once.
    /// Only value snapshots cross the worker boundary, never this mutable store.
    @MainActor
    func importBooks(from urls: [URL]) async -> [ImportOutcome] {
        let baseline = books.reduce(into: [String: BookEntity]()) { $0[$1.id] = $1 }
        let removals = removalGenerations
        let resources = ImportResources(fileManager: fileManager, defaults: nil)
        let directory = importDirectory
        var prepared: [(URL, Result<PreparedLibraryImport, Error>)] = []
        for url in urls {
            do {
                try Task.checkCancellation()
                let value = try await LibraryImportExecutor.perform {
                    try LibraryImportPreparation.prepare(from: url, fileManager: resources.fileManager, importDirectory: directory)
                }
                prepared.append((url, .success(value)))
            } catch {
                prepared.append((url, .failure(error)))
            }
        }
        var changed = false
        var mergedBooks = books
        let outcomes = prepared.map { url, result -> ImportOutcome in
            switch result {
            case .success(let value):
                guard !Task.isCancelled, removalGenerations[value.book.id] == removals[value.book.id] else {
                    return ImportOutcome(url: url, book: nil, error: "Import was cancelled or the book was removed during preparation.")
                }
                let book = Self.mergeImport(value, baseline: baseline[value.book.id], into: &mergedBooks)
                changed = true
                return ImportOutcome(url: url, book: book, error: nil)
            case .failure(let error):
                return ImportOutcome(url: url, book: nil, error: error.localizedDescription)
            }
        }
        if changed {
            let previousBooks = books
            books = mergedBooks
            persist()
            do {
                // Inbox callers may delete their source only after this task
                // completes with a published and committed durable index entry.
                try await flushPersistence()
            } catch {
                let publishedBooks = mergedBooks
                var rolledBackBooks = books
                var didRollback = false
                let importedIDs = Set(outcomes.compactMap { $0.book?.id })
                for bookID in importedIDs {
                    guard let published = publishedBooks.first(where: { $0.id == bookID }),
                          let currentIndex = rolledBackBooks.firstIndex(where: { $0.id == bookID }),
                          rolledBackBooks[currentIndex] == published else {
                        continue
                    }
                    if let previous = previousBooks.first(where: { $0.id == bookID }) {
                        rolledBackBooks[currentIndex] = previous
                    } else {
                        rolledBackBooks.remove(at: currentIndex)
                    }
                    didRollback = true
                }
                if didRollback {
                    books = rolledBackBooks
                    persist()
                }
                return outcomes.map { outcome in
                    guard outcome.book != nil else { return outcome }
                    return ImportOutcome(url: outcome.url, book: nil,
                                         error: "Library persistence failed: \(error.localizedDescription)")
                }
            }
        }
        return outcomes
    }

    @MainActor
    func importBookAsync(from url: URL) async throws -> BookEntity {
        let outcomes = await importBooks(from: [url])
        guard let outcome = outcomes.first, let book = outcome.book else {
            throw NSError(domain: "LibraryStore", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: outcomes.first?.error ?? "Book import failed."])
        }
        return book
    }

    private static func mergeImport(_ prepared: PreparedLibraryImport, baseline: BookEntity?, into books: inout [BookEntity]) -> BookEntity {
        let incoming = prepared.book
        if let existingIndex = books.firstIndex(where: { $0.id == incoming.id }) {
            var existing = books[existingIndex]
            existing.bookmark = incoming.bookmark
            existing.fileType = incoming.fileType
            if existing.lastOpenedAt == baseline?.lastOpenedAt { existing.lastOpenedAt = Date() }
            if existing.title == baseline?.title, let title = prepared.metadataTitle, !title.isEmpty {
                existing.title = title
            }
            if existing.author == baseline?.author {
                if let author = prepared.metadataAuthor, !author.isEmpty { existing.author = author }
                else if LibraryIndexCodec.isParserErrorText(existing.author ?? "") { existing.author = nil }
            }
            if existing.coverPNG == baseline?.coverPNG, existing.coverPNG == nil, let cover = incoming.coverPNG {
                existing.coverPNG = cover
            }
            books[existingIndex] = existing
            return existing
        }
        books.append(incoming)
        return incoming
    }

    /// Remove a book from the library. Does NOT delete the underlying
    /// file (the user may want it back).
    func remove(id: String) {
        removalGenerations[id, default: 0] += 1
        ReaderProgressStore.evict(bookId: id)
        books.removeAll { $0.id == id }
        persist()
    }

    func update(_ book: BookEntity) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i] = book
        persist()
    }

    func installUITestFixtureIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains("-uiTestFixture") else { return }
        // The reader replaces this metadata-only entry with an in-memory
        // payload before attempting bookmark resolution. Keeping the fixture
        // in code avoids coupling every UI test to a binary EPUB resource in
        // the app bundle, which previously made the entire suite silently
        // skip when that resource was not packaged.
        books = [
            BookEntity(
                id: "ui-test-book",
                title: "UI Test Book",
                author: "UI Test Author",
                bookmark: Data(),
                displayFilename: "ui-test-book.epub",
                addedAt: .distantPast,
                fileType: .epub
            )
        ]
        loadError = nil
    }

    /// Resolve the bookmark to a file URL the caller can read. Marks
    /// `lastOpenedAt = now` as a side effect so the Library can sort by
    /// "recently opened".
    ///
    /// Throws when the bookmark is missing or empty (preview fixtures,
    /// or an iOS import where bookmark creation failed). Without this
    /// guard, `URL(resolvingBookmarkData: Data())` raises
    /// `fatalError` inside libswiftCore — which is exactly what was
    /// crashing the native UI preview.
    func openBookFile(id: String) throws -> URL {
        guard let i = books.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "LibraryStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Book not found in library"])
        }
        guard !books[i].bookmark.isEmpty else {
            throw NSError(
                domain: "LibraryStore",
                code: 410,
                userInfo: [NSLocalizedDescriptionKey:
                    "This book has no security-scoped bookmark (re-import \(books[i].displayFilename) from the file picker to restore access)."]
            )
        }
        // Try security-scoped resolution first (matches a sandboxed
        // signed build); fall back to a plain resolution so unsigned
        // Debug runs still work after switching configs.
        let resolved = try LibraryBookmarkAccess.resolveBookBookmark(books[i].bookmark)
        let stale = resolved.stale
        var url = resolved.url
        #if os(macOS)
        if !LibraryImportFiles.isAppOwnedLibraryURL(url, baseDirectory: importDirectory) {
            // Migrate books imported by older builds. Keep the security scope
            // alive only for the copy operation, then use the internal copy
            // for every subsequent open.
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let durableURL = try LibraryImportFiles.persistImportedFileForLibrary(
                originalURL: url,
                id: books[i].id,
                fileType: books[i].fileType,
                fileManager: fileManager,
                baseDirectory: importDirectory
            )
            books[i].bookmark = try LibraryBookmarkAccess.makeBookmark(for: durableURL)
            url = durableURL
        } else if stale, let fresh = try? LibraryBookmarkAccess.makeBookmark(for: url) {
            books[i].bookmark = fresh
        }
        #else
        if stale, let fresh = try? LibraryBookmarkAccess.makeBookmark(for: url) {
            books[i].bookmark = fresh
        }
        #endif
        books[i].lastOpenedAt = Date()
        persist()
        return url
    }

    /// Async variant of `openBookFile(id:)` for reader flows. Bookmark
    /// resolution can wait for iCloud I/O, so that non-cancellable system
    /// call must never occupy the main actor while the reader is showing its
    /// loading state.
    @MainActor
    func openBookFileAsync(id: String) async throws -> URL {
        guard let initialIndex = books.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "LibraryStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Book not found in library"])
        }
        let bookmark = books[initialIndex].bookmark
        guard !bookmark.isEmpty else {
            throw NSError(
                domain: "LibraryStore",
                code: 410,
                userInfo: [NSLocalizedDescriptionKey:
                    "This book has no security-scoped bookmark (re-import \(books[initialIndex].displayFilename) from the file picker to restore access)."]
            )
        }

        let resolved = try await LibraryBookmarkAccess.resolveBookBookmarkAsync(bookmark)
        let stale = resolved.stale
        var url = resolved.url

        guard let currentIndex = books.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "LibraryStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Book was removed from library while opening"])
        }
        #if os(macOS)
        if !LibraryImportFiles.isAppOwnedLibraryURL(url, baseDirectory: importDirectory) {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let durableURL = try LibraryImportFiles.persistImportedFileForLibrary(
                originalURL: url,
                id: books[currentIndex].id,
                fileType: books[currentIndex].fileType,
                fileManager: fileManager,
                baseDirectory: importDirectory
            )
            books[currentIndex].bookmark = try LibraryBookmarkAccess.makeBookmark(for: durableURL)
            url = durableURL
        } else if stale, let fresh = try? LibraryBookmarkAccess.makeBookmark(for: url) {
            books[currentIndex].bookmark = fresh
        }
        #else
        if stale, let fresh = try? LibraryBookmarkAccess.makeBookmark(for: url) {
            books[currentIndex].bookmark = fresh
        }
        #endif
        books[currentIndex].lastOpenedAt = Date()
        persist()
        return url
    }

    // MARK: - Tags

    var allTags: [String] {
        Array(Set(books.flatMap { $0.tags })).sorted()
    }

    func addTag(_ tag: String, to bookId: String) {
        guard let i = books.firstIndex(where: { $0.id == bookId }) else { return }
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !books[i].tags.contains(normalized) else { return }
        books[i].tags.append(normalized)
        persist()
    }

    func removeTag(_ tag: String, from bookId: String) {
        guard let i = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[i].tags.removeAll { $0 == tag }
        persist()
    }

    func books(withTag tag: String) -> [BookEntity] {
        books.filter { $0.tags.contains(tag) }
    }

    func recordConversion(jobId: String, for bookId: String, cachedOffline: Bool = false) {
        guard let index = books.firstIndex(where: { $0.id == bookId }) else { return }
        books[index].lastJobId = jobId
        books[index].cachedOffline = cachedOffline
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        indexPersistence.enqueue(books)
    }

    /// Flushes submissions preceding this call without blocking the main actor.
    /// UserDefaults acceptance is not an fsync or power-loss durability guarantee.
    func flushPersistence() async throws {
        try await indexPersistence.flush()
    }

    /// For synchronous compatibility callers/tests or a termination hook only.
    /// Interactive mutation paths must never wait on this barrier.
    func flushPersistenceSync() throws {
        try indexPersistence.flushSync()
    }

    // MARK: - Durable import storage


}


#if DEBUG
extension LibraryStore {
    static var previewEmpty: LibraryStore {
        let suite = "library.preview.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
    }

    static var previewPopulated: LibraryStore {
        let suite = "library.preview.full.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        let now = Date()
        store.books = LibraryPreviewBooks.populated(now: now)
        return store
    }
}
#endif
