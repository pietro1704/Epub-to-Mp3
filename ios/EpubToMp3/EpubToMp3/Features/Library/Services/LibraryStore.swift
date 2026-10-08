import Foundation
import CryptoKit
import Combine
import Darwin

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
    private static let importQueue = DispatchQueue(label: "com.epubtomp3.library-import", qos: .userInitiated,
                                                  autoreleaseFrequency: .workItem)
    private let indexPersistence: LibraryIndexPersistence
    private let importDirectory: URL?
    private var removalGenerations: [String: Int] = [:]
    private static let applicationSupportFolderName = "EpubToMp3"
    private static let developmentSeedBookFilename = "EpubToMp3DevelopmentSeed.epub"

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
        apply(Self.decode(data: defaults.data(forKey: defaultsKey)))
    }

    private func apply(_ outcome: DecodeOutcome) {
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

    /// Outcome of the persisted-library decode.
    private enum DecodeOutcome: Sendable {
        case success((books: [BookEntity], needsPersist: Bool))
        case failure(String)
        case empty
    }

    /// Single decode + migrate pipeline shared by both load paths.
    private static func decode(data: Data?) -> DecodeOutcome {
        guard let data else { return .empty }
        do {
            let decoded = try JSONDecoder().decode([BookEntity].self, from: data)
            let pruned = decoded.filter { !$0.bookmark.isEmpty }
            var migrated = false
            var result = pruned
            for i in result.indices {
                if let author = result[i].author,
                   Self.isParserErrorText(author) {
                    result[i].author = nil
                    migrated = true
                }
                if let cover = result[i].coverPNG,
                   cover.count > LibraryStore.coverMaxBytes {
                    result[i].coverPNG = LibraryStore.downsampleCover(cover)
                    migrated = true
                }
            }
            return .success((result, pruned.count != decoded.count || migrated))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func isParserErrorText(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("parse timed out")
            || normalized.contains("python parser")
            || normalized.contains("failed to parse epub")
            || normalized.hasPrefix("reader.")
            || normalized.hasPrefix("bookopen.")
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
        let prepared = try Self.importQueue.sync {
            try Self.prepareImport(from: url, fileManager: fileManager, importDirectory: importDirectory)
        }
        let baseline = books.first(where: { $0.id == prepared.book.id })
        let book = Self.mergeImport(prepared, baseline: baseline, into: &books)
        persist()
        // This legacy blocking API retains its immediate-reload contract.
        try flushPersistenceSync()
        return book
    }

    struct ImportOutcome: Sendable {
        let url: URL
        let book: BookEntity?
        let error: String?
    }

    /// Immutable references to Foundation's thread-safe IO services. Only these
    /// resources cross the serial import worker; the mutable store never does.
    /// Injected subclasses must synchronize any additional mutable test state.
    struct ImportResources: @unchecked Sendable {
        let fileManager: FileManager
        let defaults: UserDefaults?
    }

    private struct PreparedImport: Sendable {
        let book: BookEntity
        let metadataTitle: String?
        let metadataAuthor: String?
    }

    /// A batch performs one preparation at a time, then merges and persists once.
    /// Only value snapshots cross the worker boundary, never this mutable store.
    @MainActor
    func importBooks(from urls: [URL]) async -> [ImportOutcome] {
        let baseline = books.reduce(into: [String: BookEntity]()) { $0[$1.id] = $1 }
        let removals = removalGenerations
        let resources = ImportResources(fileManager: fileManager, defaults: nil)
        let directory = importDirectory
        var prepared: [(URL, Result<PreparedImport, Error>)] = []
        for url in urls {
            do {
                try Task.checkCancellation()
                let value = try await Self.performImportIO {
                    try Self.prepareImport(from: url, fileManager: resources.fileManager, importDirectory: directory)
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
            books = mergedBooks
            persist()
            do {
                // Inbox callers may delete their source only after this task
                // completes with a published and committed durable index entry.
                try await flushPersistence()
            } catch {
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

    /// Also used by inbox/Document callers for enumeration and source cleanup.
    static func performImportIO<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            importQueue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    private static func prepareImport(
        from url: URL, fileManager: FileManager, importDirectory: URL?
    ) throws -> PreparedImport {
        guard url.isFileURL, !url.path.isEmpty else {
            throw NSError(
                domain: "LibraryStore",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "The selected book URL is invalid or unavailable."]
            )
        }
        // Sandbox: the parent grants us access to the user-picked URL
        // for the duration of this scope. We must ensure every read
        // (hash, bookmark, metadata) happens INSIDE the same
        // start/stop pair — re-entering `startAccessing…` later in
        // a different stack frame is not equivalent.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        // Apple Books can expose a book as an expanded `.epub` directory.
        // Materialise it while the security scope is active, then let the
        // regular import path own a normal archive just like any other EPUB.
        let materialized = try EpubDirectoryArchiver.materializeIfNeeded(at: url, fileManager: fileManager)
        defer {
            if materialized.isTemporary {
                try? fileManager.removeItem(at: materialized.url)
            }
        }
        let importURL = materialized.url

        // Verify we can actually read the file before touching disk
        // for the bookmark — this gives the user a clearer error than
        // the generic "couldn't be opened" surfaced by the system.
        guard fileManager.isReadableFile(atPath: importURL.path) else {
            throw NSError(
                domain: "LibraryStore",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Cannot read \(url.lastPathComponent). The system denied access — try moving the file to a folder the app has permission to read (Documents, Downloads), or re-pick it from the file picker."
                ]
            )
        }

        let id: String
        do {
            id = try Self.contentHash(of: importURL)
        } catch {
            throw NSError(
                domain: "LibraryStore",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Failed to read \(url.lastPathComponent): \(error.localizedDescription)"
                ]
            )
        }

        let filename = url.lastPathComponent
        let fileType = BookFileType.detect(from: url)
        guard fileType != .unsupported else {
            throw NSError(
                domain: "LibraryStore",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        L10n.string("library.unsupportedFormat", filename)
                ]
            )
        }
        // Keep the user's original file untouched. The app-owned copy means
        // future launches can read the book without reopening the user's
        // Documents/Downloads permission scope.
        let libraryURL = try Self.persistImportedFileForLibrary(
            originalURL: importURL,
            id: id,
            fileType: fileType,
            fileManager: fileManager,
            baseDirectory: importDirectory
        )

        // The bookmark points at the durable app-owned copy rather than the
        // picker/inbox handoff URL that may be moved or deleted later.
        let bookmark: Data
        do {
            bookmark = try Self.makeBookmark(for: libraryURL)
        } catch {
            #if os(macOS)
            throw NSError(
                domain: "LibraryStore",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Cannot remember access to \(url.lastPathComponent). The system refused to create a security-scoped bookmark — try moving the file to ~/Documents and re-import."
                ]
            )
            #else
            bookmark = Data()
            #endif
        }

        // Route to the right metadata reader. PDFKit handles `.pdf`; every
        // other format goes through the in-process EPUB/zip-oriented reader
        // best-effort (`try?` swallows a parse failure and falls back to an
        // empty payload — the caller below then derives a title from the
        // filename). Formats that need dedicated metadata extraction
        // (FB2/DOCX/CBZ title-info) can replace this fallback per-case
        // later without touching the dispatch shape.
        let resolvedTitle: String?
        let resolvedAuthor: String?
        let resolvedCover: Data?
        switch fileType {
        case .pdf:
            let payload: PdfMetadataReader.Payload
            do {
                payload = try PdfMetadataReader.readMetadata(from: libraryURL)
            } catch let err as PdfMetadataReader.ReaderError {
                throw NSError(
                    domain: "LibraryStore",
                    code: 5,
                    userInfo: [
                        NSLocalizedDescriptionKey: err.errorDescription
                            ?? "PDF metadata read failed for \(filename)."
                    ]
                )
            }
            resolvedTitle = payload.title
            resolvedAuthor = payload.author
            resolvedCover = Self.downsampleCover(payload.cover)
        case .epub, .fb2, .docx, .cbz, .cbr, .mobi, .azw3, .unsupported:
            // Metadata is optional. A malformed container must not abort the
            // import after the app-owned copy has already been created.
            let payload = (try? EpubMetadataReader.readMetadata(from: libraryURL)) ?? .init()
            resolvedTitle = payload.title
            resolvedAuthor = Self.isParserErrorText(payload.author ?? "") ? nil : payload.author
            resolvedCover = Self.downsampleCover(payload.cover)
        }

        let book = BookEntity(
            id: id,
            title: resolvedTitle ?? Self.titleFromFilename(filename),
            author: resolvedAuthor,
            bookmark: bookmark,
            displayFilename: filename,
            addedAt: Date(),
            coverPNG: resolvedCover,
            fileType: fileType
        )
        return PreparedImport(book: book, metadataTitle: resolvedTitle, metadataAuthor: resolvedAuthor)
    }

    private static func mergeImport(_ prepared: PreparedImport, baseline: BookEntity?, into books: inout [BookEntity]) -> BookEntity {
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
                else if Self.isParserErrorText(existing.author ?? "") { existing.author = nil }
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

    /// Imports a book staged by the local development launch commands. The
    /// book never ships in the app bundle and this path only runs when the
    /// explicit launch argument is present.
    @discardableResult
    func installDevelopmentSeedBookIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        seedURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard arguments.contains("-developmentSeedBook") else { return false }
        let resolvedURL = seedURL ?? Self.developmentSeedBookURL(fileManager: fileManager)
        guard let resolvedURL,
              fileManager.isReadableFile(atPath: resolvedURL.path) else {
            return false
        }

        do {
            let id = try Self.contentHash(of: resolvedURL)
            if !books.contains(where: { $0.id == id }) {
                _ = try importBook(from: resolvedURL)
            }
            return true
        } catch {
            print("Failed to install development seed book: \(error)")
            return false
        }
    }

    private static func developmentSeedBookURL(fileManager: FileManager) -> URL? {
        guard let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return documents.appendingPathComponent(developmentSeedBookFilename)
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
        var stale = false
        var url: URL
        #if os(macOS)
        if let scoped = try? Self.resolveBookmarkWithTimeout(
            books[i].bookmark, options: [.withSecurityScope]
        ) {
            url = scoped.url
            stale = scoped.stale
        } else {
            let resolved = try Self.resolveBookmarkWithTimeout(
                books[i].bookmark, options: []
            )
            url = resolved.url
            stale = resolved.stale
        }
        #else
        let resolved = try Self.resolveBookmarkWithTimeout(
            books[i].bookmark, options: []
        )
        url = resolved.url
        stale = resolved.stale
        #endif
        #if os(macOS)
        if !Self.isAppOwnedLibraryURL(url, baseDirectory: importDirectory) {
            // Migrate books imported by older builds. Keep the security scope
            // alive only for the copy operation, then use the internal copy
            // for every subsequent open.
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let durableURL = try Self.persistImportedFileForLibrary(
                originalURL: url,
                id: books[i].id,
                fileType: books[i].fileType,
                fileManager: fileManager,
                baseDirectory: importDirectory
            )
            books[i].bookmark = try Self.makeBookmark(for: durableURL)
            url = durableURL
        } else if stale, let fresh = try? Self.makeBookmark(for: url) {
            books[i].bookmark = fresh
        }
        #else
        if stale, let fresh = try? Self.makeBookmark(for: url) {
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

        var stale = false
        var url: URL
        #if os(macOS)
        if let scoped = try? await Self.resolveBookmarkWithTimeoutAsync(
            bookmark, options: [.withSecurityScope]
        ) {
            url = scoped.url
            stale = scoped.stale
        } else {
            let resolved = try await Self.resolveBookmarkWithTimeoutAsync(
                bookmark, options: []
            )
            url = resolved.url
            stale = resolved.stale
        }
        #else
        let resolved = try await Self.resolveBookmarkWithTimeoutAsync(
            bookmark, options: []
        )
        url = resolved.url
        stale = resolved.stale
        #endif

        guard let currentIndex = books.firstIndex(where: { $0.id == id }) else {
            throw NSError(domain: "LibraryStore", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "Book was removed from library while opening"])
        }
        #if os(macOS)
        if !Self.isAppOwnedLibraryURL(url, baseDirectory: importDirectory) {
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let durableURL = try Self.persistImportedFileForLibrary(
                originalURL: url,
                id: books[currentIndex].id,
                fileType: books[currentIndex].fileType,
                fileManager: fileManager,
                baseDirectory: importDirectory
            )
            books[currentIndex].bookmark = try Self.makeBookmark(for: durableURL)
            url = durableURL
        } else if stale, let fresh = try? Self.makeBookmark(for: url) {
            books[currentIndex].bookmark = fresh
        }
        #else
        if stale, let fresh = try? Self.makeBookmark(for: url) {
            books[currentIndex].bookmark = fresh
        }
        #endif
        books[currentIndex].lastOpenedAt = Date()
        persist()
        return url
    }

    /// `URL(resolvingBookmarkData:)` is a synchronous, non-cancellable
    /// system call. For a bookmark pointing at an iCloud-backed file that
    /// isn't downloaded locally, resolution can stall for a long time (or
    /// indefinitely on a bad connection) waiting on the download —
    /// blocking whichever thread called it. `openBookFile` runs inside
    /// `BookOpenScreenController.loadBook()`'s `Task { }`, which — created
    /// from a `@MainActor` method — inherits MainActor isolation, so a
    /// stuck resolve here froze the entire app, not just the reader's
    /// spinner ("carregamento infinito"). Bound it with a hard deadline:
    /// still blocks the calling thread for that window (this API can't be
    /// cancelled), but guarantees the caller gets control back and can
    /// surface a real error instead of hanging forever.
    private static func resolveBookmarkWithTimeout(
        _ bookmark: Data,
        options: URL.BookmarkResolutionOptions,
        timeout: TimeInterval = 10
    ) throws -> BookmarkResolution {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResolveResultBox()
        DispatchQueue.global(qos: .userInitiated).async {
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: options,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                box.result = .success(BookmarkResolution(url: url, stale: stale))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw NSError(
                domain: "LibraryStore",
                code: 408,
                userInfo: [NSLocalizedDescriptionKey:
                    "Timed out opening this book's file — it may be stuck downloading from iCloud. Check your connection and try again."]
            )
        }
        guard let result = box.result else {
            throw NSError(domain: "LibraryStore", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "Bookmark resolution finished without a result."])
        }
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }

    private static func resolveBookmarkWithTimeoutAsync(
        _ bookmark: Data,
        options: URL.BookmarkResolutionOptions,
        timeout: TimeInterval = 10
    ) async throws -> BookmarkResolution {
        try await Task.detached(priority: .userInitiated) {
            try Self.resolveBookmarkWithTimeout(
                bookmark,
                options: options,
                timeout: timeout
            )
        }.value
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

    static func persistImportedFileForLibrary(
        originalURL: URL,
        id: String,
        fileType: BookFileType,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) throws -> URL {
        let root = try importedBooksDirectory(fileManager: fileManager, baseDirectory: baseDirectory)
        let bookDirectory = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)

        let fallbackName = "Book.\(fileType.rawValue)"
        let fileName = originalURL.lastPathComponent.isEmpty ? fallbackName : originalURL.lastPathComponent
        let destination = bookDirectory.appendingPathComponent(fileName, isDirectory: false)
        if originalURL.resolvingSymlinksInPath().standardizedFileURL.path
            == destination.resolvingSymlinksInPath().standardizedFileURL.path {
            return destination
        }
        // Reserve an owned sibling directory on the same volume. A failed or
        // partial copy cannot damage the previously imported book.
        let staging = bookDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let reserved = staging.path.withCString { mkdir($0, mode_t(0o700)) }
        guard reserved == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { try? fileManager.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent(fileName)
        try fileManager.copyItem(at: originalURL, to: stagedFile)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedFile)
        } else {
            try fileManager.moveItem(at: stagedFile, to: destination)
        }
        return destination
    }

    private static func importedBooksDirectory(
        fileManager: FileManager,
        baseDirectory: URL?
    ) throws -> URL {
        if let baseDirectory {
            return baseDirectory
        }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
            .appendingPathComponent("ImportedBooks", isDirectory: true)
    }

    #if os(macOS)
    private static func isAppOwnedLibraryURL(_ url: URL, baseDirectory: URL? = nil) -> Bool {
        guard let root = try? importedBooksDirectory(
            fileManager: .default,
            baseDirectory: baseDirectory
        ) else {
            return false
        }
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
    #endif

    // MARK: - Bookmark helpers

    private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        // We may hold a non-security-scoped bookmark when the app is
        // running unsigned (Debug builds) — the system lets us resolve
        // either kind with the same call when we leave the option off.
        // We try the scoped resolution first via the resolver below.
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    /// Best-effort bookmark creation. macOS sandbox + signed app →
    /// security-scoped bookmark. Unsigned Debug runs (no sandbox) →
    /// regular bookmark. iOS → `suitableForBookmarkFile`. We always
    /// return *something* the user can resolve next launch.
    private static func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        return try url.bookmarkData(
            options: [.suitableForBookmarkFile],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
    }

    // MARK: - Hashing

    /// SHA-256 of the file contents. 32 hex chars are plenty for a
    /// stable id inside a single user's library. Uses memory-mapped
    /// `Data(contentsOf:)` so the kernel pages the file in lazily —
    /// hashes a 50 MB EPUB without allocating 50 MB of RAM.
    ///
    /// Memory-mapped also dodges a class of sandbox failures: where
    /// `FileHandle(forReadingFrom:)` would surface "couldn't be
    /// opened" inconsistently if the security-scoped access window had
    /// just expired between calls, `Data(contentsOf:)` reads in one
    /// shot under the still-active scope.
    static func contentHash(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.alwaysMapped])
        var hasher = SHA256()
        hasher.update(data: data)
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    private static func titleFromFilename(_ name: String) -> String {
        let trimmed = (name as NSString).deletingPathExtension
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    // MARK: - Cover downsampling

    /// Maximum pixel dimensions for stored cover art. Widget surfaces
    /// render at ~200x300pt max, so anything larger wastes UserDefaults
    /// space. Downsampled covers use JPEG compression (0.7 quality) to
    /// stay under ~30-50 KB per book.
    private static let coverMaxWidth: CGFloat = 200
    private static let coverMaxHeight: CGFloat = 300
    /// JPEG quality factor. 0.7 gives a good balance between size and
    /// visual fidelity at thumbnail resolution.
    private static let coverJPEGQuality: CGFloat = 0.7
    /// Any cover blob larger than this threshold is considered oversized
    /// and will be downsampled. Prevents large PNG/JPEG data from
    /// bloating the shared UserDefaults (which has a ~4 MB practical
    /// limit across the App Group suite).
    private static let coverMaxBytes = 80_000

    /// Downsample raw cover image data to fit within `coverMaxWidth` x
    /// `coverMaxHeight` and compress as JPEG. Returns the original data
    /// unchanged if it is already small enough.
    static func downsampleCover(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        // Already small enough — keep as-is.
        if data.count <= coverMaxBytes {
            return data
        }
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return data }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return data }
        let scale = min(
            coverMaxWidth / size.width,
            coverMaxHeight / size.height,
            1.0 // never upscale
        )
        if scale >= 1.0 {
            // Image fits but is just stored in an uncompressed format.
            // Re-encode as JPEG to shrink it.
            return image.jpegData(compressionQuality: coverJPEGQuality) ?? data
        }
        let targetSize = CGSize(
            width: floor(size.width * scale),
            height: floor(size.height * scale)
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: coverJPEGQuality) ?? data
        #else
        guard let image = NSImage(data: data) else { return data }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return data }
        let scale = min(
            coverMaxWidth / size.width,
            coverMaxHeight / size.height,
            1.0
        )
        let targetSize: CGSize
        if scale >= 1.0 {
            targetSize = size
        } else {
            targetSize = CGSize(
                width: floor(size.width * scale),
                height: floor(size.height * scale)
            )
        }
        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep = bitmapRep else { return data }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: CGRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: coverJPEGQuality]
        ) ?? data
        #endif
    }
}

/// Queue-confined writer. Foundation UserDefaults is thread-safe; mutable error
/// state is accessed only on the serial queue. No LibraryStore reference crosses
/// this boundary, and queued snapshots are immutable Sendable values.
private final class LibraryIndexPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.epubtomp3.library-index", qos: .utility,
                                      autoreleaseFrequency: .workItem)
    private let defaults: UserDefaults
    private let key: String
    private let encoder: @Sendable ([BookEntity]) throws -> Data
    private var lastFailure: Error?

    init(defaults: UserDefaults, key: String,
         encoder: @escaping @Sendable ([BookEntity]) throws -> Data) {
        self.defaults = defaults
        self.key = key
        self.encoder = encoder
    }

    func enqueue(_ snapshot: [BookEntity]) {
        queue.async { [self] in
            do {
                let data = try encoder(snapshot)
                defaults.set(data, forKey: key)
                lastFailure = nil
                WidgetDataSync.reloadLibraryWidgets()
            } catch {
                lastFailure = error
                NSLog("Library persistence failed: %@", error.localizedDescription)
            }
        }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let lastFailure { continuation.resume(throwing: lastFailure) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func flushSync() throws {
        try queue.sync {
            if let lastFailure { throw lastFailure }
        }
    }
}

/// Cross-thread result box for `resolveBookmarkWithTimeout` — the
/// resolution work runs on `DispatchQueue.global()` while the caller waits
/// on a semaphore, so the result needs a `Sendable` carrier between them.
private struct BookmarkResolution: Sendable {
    let url: URL
    let stale: Bool
}

private final class ResolveResultBox: @unchecked Sendable {
    var result: Result<BookmarkResolution, Error>?
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
        store.books = [
            BookEntity(
                id: "preview-1",
                title: "Foundation",
                author: "Isaac Asimov",
                bookmark: Data(),
                displayFilename: "foundation.epub",
                addedAt: now.addingTimeInterval(-86400 * 7),
                lastOpenedAt: now.addingTimeInterval(-3600),
                lastChapterIndex: 2,
                lastPositionSeconds: 73,
                coverPNG: nil,
                lastJobId: nil,
                cachedOffline: false
            ),
            BookEntity(
                id: "preview-2",
                title: "Metro 2033",
                author: "Dmitry Glukhovsky",
                bookmark: Data(),
                displayFilename: "metro2033.epub",
                addedAt: now.addingTimeInterval(-86400 * 30),
                lastOpenedAt: now.addingTimeInterval(-86400),
                lastChapterIndex: 12,
                lastPositionSeconds: 0,
                coverPNG: nil,
                lastJobId: "preview-job-id",
                cachedOffline: true
            ),
            BookEntity(
                id: "preview-3",
                title: "O Hobbit",
                author: "J.R.R. Tolkien",
                bookmark: Data(),
                displayFilename: "o_hobbit.epub",
                addedAt: now.addingTimeInterval(-86400 * 2),
                lastOpenedAt: nil,
                lastChapterIndex: nil,
                lastPositionSeconds: nil,
                coverPNG: nil,
                lastJobId: "preview-pending",
                cachedOffline: false
            ),
        ]
        return store
    }
}
#endif
