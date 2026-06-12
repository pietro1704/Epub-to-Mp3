import Foundation
import CryptoKit
import Combine

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
/// Security-scoped bookmarks are required on macOS sandbox + iOS so we
/// can keep reading the user's `.epub` after the app restarts. The
/// caller is responsible for invoking `startAccessingSecurityScopedResource()`
/// once before each I/O burst — `LibraryStore.openBookFile` does that.
///
/// Persistence target: the App Group suite (`group.com.pietrocode.epubtomp3`)
/// is used when available — this lets the WidgetKit extension (`EpubToMp3Widget`)
/// read the same `"library.books.v1"` key without IPC. Falls back to
/// `.standard` on simulators without a provisioned group and in unit tests.
final class LibraryStore: ObservableObject {
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
        fileManager: FileManager = .default
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
        // When the caller injected a UserDefaults instance directly,
        // we're almost certainly in a test or preview context — load
        // synchronously so assertions made right after `init` see the
        // persisted state. Production app-group defaults still take
        // the detached path so the main thread isn't blocked by a
        // large persisted JSON (book covers inflate decode time).
        if defaults != nil {
            loadSync()
        } else {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loadAsync()
            }
        }
    }

    /// Synchronous on-actor load. Used by test/preview inits where the
    /// caller passed a specific `UserDefaults` and expects the books
    /// array to be hydrated before control returns.
    private func loadSync() {
        switch Self.decode(defaults: defaults, key: defaultsKey) {
        case .success(let (books, needsPersist)):
            self.books = books
            if needsPersist { persist() }
        case .failure(let error):
            self.loadError = error.localizedDescription
        case .empty:
            break
        }
    }

    /// Async load on a background actor — production path. Same
    /// decode logic as `loadSync`, just dispatched off main.
    private func loadAsync() async {
        let outcome = Self.decode(defaults: defaults, key: defaultsKey)
        await MainActor.run {
            switch outcome {
            case .success(let (books, needsPersist)):
                self.books = books
                if needsPersist { self.persist() }
            case .failure(let error):
                self.loadError = error.localizedDescription
            case .empty:
                break
            }
        }
    }

    /// Outcome of the persisted-library decode.
    private enum DecodeOutcome {
        case success((books: [BookEntity], needsPersist: Bool))
        case failure(Error)
        case empty
    }

    /// Single decode + migrate pipeline shared by both load paths.
    private static func decode(
        defaults: UserDefaults,
        key: String
    ) -> DecodeOutcome {
        guard let data = defaults.data(forKey: key) else { return .empty }
        do {
            let decoded = try JSONDecoder().decode([BookEntity].self, from: data)
            let pruned = decoded.filter { !$0.bookmark.isEmpty }
            var migrated = false
            var result = pruned
            for i in result.indices {
                if let cover = result[i].coverPNG,
                   cover.count > LibraryStore.coverMaxBytes {
                    result[i].coverPNG = LibraryStore.downsampleCover(cover)
                    migrated = true
                }
            }
            return .success((result, pruned.count != decoded.count || migrated))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - CRUD

    /// Import a new book from a file picker URL. The URL must be
    /// "fresh" — i.e. the caller already received it from a sandboxed
    /// `fileImporter`/`UIDocumentPickerViewController`. We:
    ///
    /// 1. Read enough of the file to compute a content hash (the id).
    /// 2. Persist a security-scoped bookmark.
    /// 3. Best-effort parse title/author/cover from EPUB metadata.
    /// 4. De-dupe — if the same content hash is already in the library,
    ///    refresh its bookmark + filename and skip the rest.
    @discardableResult
    func importBook(from url: URL) throws -> BookEntity {
        // Sandbox: the parent grants us access to the user-picked URL
        // for the duration of this scope. We must ensure every read
        // (hash, bookmark, metadata) happens INSIDE the same
        // start/stop pair — re-entering `startAccessing…` later in
        // a different stack frame is not equivalent.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        // Verify we can actually read the file before touching disk
        // for the bookmark — this gives the user a clearer error than
        // the generic "couldn't be opened" surfaced by the system.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
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
            id = try Self.contentHash(of: url)
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
        let libraryURL: URL
        #if os(iOS)
        libraryURL = try Self.persistImportedFileForLibrary(
            originalURL: url,
            id: id,
            fileType: fileType
        )
        #else
        libraryURL = url
        #endif

        // Bookmark creation must succeed on macOS — the sandbox needs
        // it to grant the app access on the next launch. On iOS the
        // imported file is copied into the app sandbox first, so the
        // bookmark points at a durable URL rather than the picker/inbox
        // handoff URL that Files may delete after import.
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

        // Route to the right metadata reader. PDFKit handles `.pdf`;
        // the in-process EPUB reader handles `.epub` (plus anything we
        // can't classify — the EPUB reader returns an empty payload
        // for non-zip inputs, so the fall-through is safe).
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
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey: err.errorDescription
                            ?? "PDF metadata read failed for \(filename)."
                    ]
                )
            }
            resolvedTitle = payload.title
            resolvedAuthor = payload.author
            resolvedCover = Self.downsampleCover(payload.cover)
        case .epub:
            let payload = (try? EpubMetadataReader.readMetadata(from: libraryURL)) ?? .init()
            resolvedTitle = payload.title
            resolvedAuthor = payload.author
            resolvedCover = Self.downsampleCover(payload.cover)
        }

        if let existingIndex = books.firstIndex(where: { $0.id == id }) {
            var existing = books[existingIndex]
            existing.bookmark = bookmark
            existing.lastOpenedAt = Date()
            existing.fileType = fileType
            if let t = resolvedTitle, !t.isEmpty { existing.title = t }
            if let a = resolvedAuthor, !a.isEmpty { existing.author = a }
            if existing.coverPNG == nil, let cover = resolvedCover {
                existing.coverPNG = cover
            }
            books[existingIndex] = existing
            persist()
            return existing
        }

        let book = BookEntity(
            id: id,
            title: resolvedTitle ?? Self.titleFromFilename(filename),
            author: resolvedAuthor,
            bookmark: bookmark,
            displayFilename: filename,
            addedAt: Date(),
            lastOpenedAt: nil,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: resolvedCover,
            lastJobId: nil,
            cachedOffline: false,
            fileType: fileType
        )
        books.append(book)
        persist()
        return book
    }

    /// Remove a book from the library. Does NOT delete the underlying
    /// file (the user may want it back).
    func remove(id: String) {
        books.removeAll { $0.id == id }
        persist()
    }

    func update(_ book: BookEntity) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i] = book
        persist()
    }

    /// Resolve the bookmark to a file URL the caller can read. Marks
    /// `lastOpenedAt = now` as a side effect so the Library can sort by
    /// "recently opened".
    ///
    /// Throws when the bookmark is missing or empty (preview fixtures,
    /// or an iOS import where bookmark creation failed). Without this
    /// guard, `URL(resolvingBookmarkData: Data())` raises
    /// `fatalError` inside libswiftCore — which is exactly what was
    /// crashing the SwiftUI preview canvas.
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
        let url: URL
        #if os(macOS)
        if let scoped = try? URL(
            resolvingBookmarkData: books[i].bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            url = scoped
        } else {
            url = try URL(
                resolvingBookmarkData: books[i].bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        }
        #else
        url = try URL(
            resolvingBookmarkData: books[i].bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        #endif
        if stale {
            // Refresh the bookmark so we don't keep prompting on every open.
            if let fresh = try? Self.makeBookmark(for: url) {
                books[i].bookmark = fresh
            }
        }
        books[i].lastOpenedAt = Date()
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

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(books)
            defaults.set(data, forKey: defaultsKey)
            // Notify widgets that the library changed.
            WidgetDataSync.reloadLibraryWidgets()
        } catch {
            self.loadError = error.localizedDescription
        }
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
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: originalURL, to: destination)
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
        return support.appendingPathComponent("ImportedBooks", isDirectory: true)
    }

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
