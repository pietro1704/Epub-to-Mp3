import Foundation
import Darwin

enum LibraryImportFiles {
    private static let applicationSupportFolderName = "EpubToMp3"
    static func persistImportedFileForLibrary(
        originalURL: URL,
        id: String,
        fileType: BookFileType,
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        expectedContentHash: String? = nil
    ) throws -> URL {
        let root = try importedBooksDirectory(fileManager: fileManager, baseDirectory: baseDirectory)
        let bookDirectory = root.appendingPathComponent(id, isDirectory: true)
        try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)

        let fallbackName = "Book.\(fileType.rawValue)"
        let fileName = originalURL.lastPathComponent.isEmpty ? fallbackName : originalURL.lastPathComponent
        let destination = bookDirectory.appendingPathComponent(fileName, isDirectory: false)
        if originalURL.resolvingSymlinksInPath().standardizedFileURL.path
            == destination.resolvingSymlinksInPath().standardizedFileURL.path {
            if let expectedContentHash, try Self.contentHash(of: destination) != expectedContentHash {
                throw Self.importContentChangedError()
            }
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
        if let expectedContentHash, try Self.contentHash(of: stagedFile) != expectedContentHash {
            throw Self.importContentChangedError()
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: stagedFile)
        } else {
            try fileManager.moveItem(at: stagedFile, to: destination)
        }
        return destination
    }

    private static func importContentChangedError() -> NSError {
        NSError(domain: "LibraryStore", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "The selected book content changed during import."])
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
    static func isAppOwnedLibraryURL(_ url: URL, baseDirectory: URL? = nil) -> Bool {
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
        try BookContentIdentity.hash(of: url)
    }

    static func titleFromFilename(_ name: String) -> String {
        let trimmed = (name as NSString).deletingPathExtension
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

}
