import Foundation
import Darwin

/// Prepares file access without mutating the library. Only the main-actor caller
/// may publish the resulting bookmark after revalidating the original entry.
enum LibraryBookOpening {
    struct Prepared: Sendable {
        let url: URL
        let bookmark: Data?
        let ownedDirectory: URL?
        let refreshedCover: Data?

        func discard(using fileManager: FileManager) {
            if let ownedDirectory { try? fileManager.removeItem(at: ownedDirectory) }
        }
    }

    static func prepare(_ book: BookEntity, fileManager: FileManager, importDirectory: URL?) throws -> Prepared {
        let resolved = try LibraryBookmarkAccess.resolveBookBookmark(book.bookmark)
        let source = resolved.url
        #if os(macOS)
        if !LibraryImportFiles.isAppOwnedLibraryURL(source, baseDirectory: importDirectory) {
            let started = source.startAccessingSecurityScopedResource()
            defer { if started { source.stopAccessingSecurityScopedResource() } }
            let root = try LibraryImportFiles.importedBooksDirectory(fileManager: fileManager,
                                                                   baseDirectory: importDirectory)
            let parent = root.appendingPathComponent(book.id, isDirectory: true)
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            // Never replace another open/import's durable file while the caller
            // is suspended. This directory becomes durable only after publication.
            let owned = parent.appendingPathComponent(".opening-\(UUID().uuidString)", isDirectory: true)
            let reserved = owned.path.withCString { mkdir($0, mode_t(0o700)) }
            guard reserved == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            do {
                let name = source.lastPathComponent.isEmpty ? "Book.\(book.fileType.rawValue)" : source.lastPathComponent
                let destination = owned.appendingPathComponent(name)
                try fileManager.copyItem(at: source, to: destination)
                return Prepared(url: destination, bookmark: try LibraryBookmarkAccess.makeBookmark(for: destination),
                                ownedDirectory: owned, refreshedCover: refreshCover(book, at: destination))
            } catch {
                try? fileManager.removeItem(at: owned)
                throw error
            }
        }
        #endif
        let refreshed = resolved.stale ? try? LibraryBookmarkAccess.makeBookmark(for: source) : nil
        return Prepared(url: source, bookmark: refreshed, ownedDirectory: nil,
                        refreshedCover: refreshCover(book, at: source))
    }

    private static func refreshCover(_ book: BookEntity, at url: URL) -> Data? {
        #if os(macOS)
        guard book.fileType == .pdf,
              (book.pdfCoverVersion ?? 0) < PdfMetadataReader.coverVersion else { return nil }
        // Optional metadata must never prevent opening a readable source. Keep
        // the old payload and retry on a later open if rendering fails.
        return LibraryCoverThumbnail.downsampleCover((try? PdfMetadataReader.readMetadata(from: url))?.cover)
        #else
        return nil
        #endif
    }
}
