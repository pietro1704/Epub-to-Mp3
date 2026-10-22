import Foundation

struct PreparedLibraryImport: Sendable {
    let book: BookEntity
    let metadataTitle: String?
    let metadataAuthor: String?
}

enum LibraryImportPreparation {
    static func prepare(
        from url: URL, fileManager: FileManager, importDirectory: URL?
    ) throws -> PreparedLibraryImport {
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
            id = try LibraryImportFiles.contentHash(of: importURL)
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
        let libraryURL = try LibraryImportFiles.persistImportedFileForLibrary(
            originalURL: importURL,
            id: id,
            fileType: fileType,
            fileManager: fileManager,
            baseDirectory: importDirectory,
            expectedContentHash: id
        )

        // The bookmark points at the durable app-owned copy rather than the
        // picker/inbox handoff URL that may be moved or deleted later.
        let bookmark: Data
        do {
            bookmark = try LibraryBookmarkAccess.makeBookmark(for: libraryURL)
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
            resolvedCover = LibraryCoverThumbnail.downsampleCover(payload.cover)
        case .epub, .fb2, .docx, .cbz, .cbr, .mobi, .azw3, .unsupported:
            // Metadata is optional. A malformed container must not abort the
            // import after the app-owned copy has already been created.
            let payload = (try? EpubMetadataReader.readMetadata(from: libraryURL)) ?? .init()
            resolvedTitle = payload.title
            resolvedAuthor = LibraryIndexCodec.isParserErrorText(payload.author ?? "") ? nil : payload.author
            resolvedCover = LibraryCoverThumbnail.downsampleCover(payload.cover)
        }

        let book = BookEntity(
            id: id,
            title: resolvedTitle ?? LibraryImportFiles.titleFromFilename(filename),
            author: resolvedAuthor,
            bookmark: bookmark,
            displayFilename: filename,
            addedAt: Date(),
            coverPNG: resolvedCover,
            fileType: fileType
        )
        return PreparedLibraryImport(book: book, metadataTitle: resolvedTitle, metadataAuthor: resolvedAuthor)
    }

}
