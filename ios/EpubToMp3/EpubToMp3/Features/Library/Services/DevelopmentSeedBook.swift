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
        guard arguments.contains("-developmentSeedBook") else { return false }
        let resolvedURL = seedURL ?? Self.developmentSeedBookURL(fileManager: fileManager)
        guard let resolvedURL,
              fileManager.isReadableFile(atPath: resolvedURL.path) else {
            return false
        }

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
