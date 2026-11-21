import Foundation

enum DevelopmentSeedBook {
    private static let developmentSeedBookFilename = "EpubToMp3DevelopmentSeed.epub"
    /// Imports a book staged by the local development launch commands. The
    /// book never ships in the app bundle and this path only runs when the
    /// explicit launch argument is present.
    @discardableResult
    static func install(
        into store: LibraryStore,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        seedURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
#if DEBUG && os(iOS)
        if let index = arguments.firstIndex(of: "-uiTestTextPDFSeed") {
            guard arguments.indices.contains(index + 1) else { return false }
            return installTextPDFFixture(arguments[index + 1], into: store, fileManager: fileManager)
        }
#endif
        guard arguments.contains("-developmentSeedBook") else { return false }
        let resolvedURL = seedURL ?? Self.developmentSeedBookURL(fileManager: fileManager)
        guard let resolvedURL,
              fileManager.isReadableFile(atPath: resolvedURL.path) else {
            return false
        }

        return importSeed(resolvedURL, into: store)
    }

    private static func importSeed(_ resolvedURL: URL, into store: LibraryStore) -> Bool {
        do {
            let id = try LibraryImportFiles.contentHash(of: resolvedURL)
            if !store.books.contains(where: { $0.id == id }) {
                _ = try store.importBook(from: resolvedURL)
            }
            return true
        } catch {
            print("Failed to install development seed book: \(error)")
            return false
        }
    }

#if DEBUG && os(iOS)
    private static func installTextPDFFixture(_ encoded: String, into store: LibraryStore, fileManager: FileManager) -> Bool {
        guard encoded.utf8.count <= 32 * 1024, let data = Data(base64Encoded: encoded),
              data.starts(with: "%PDF-".utf8) else { return false }
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("EpubToMp3UITestTextFixture.pdf")
        defer { try? fileManager.removeItem(at: directory) }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            try data.write(to: url)
            return importSeed(url, into: store)
        } catch {
            print("Failed to stage the text PDF fixture: \(error)")
            return false
        }
    }
#endif

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

}
