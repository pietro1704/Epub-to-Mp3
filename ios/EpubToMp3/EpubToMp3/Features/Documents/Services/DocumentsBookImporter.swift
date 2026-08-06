import Foundation

/// Imports books placed in the app's Documents directory through Finder file
/// sharing. Source files stay in Documents; `LibraryStore` creates its own
/// durable copy in Application Support.
enum DocumentsBookImporter {
    private static let processedKey = "documents-book-importer.processed.v1"

    @discardableResult
    static func importPending(
        into library: LibraryStore,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> [SharedContainerImporter.ImportOutcome] {
        guard let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return []
        }
        return importPending(
            in: documents,
            into: library,
            fileManager: fileManager,
            defaults: defaults
        )
    }

    /// Test seam for a non-sandbox Documents directory.
    @discardableResult
    static func importPending(
        in directory: URL,
        into library: LibraryStore,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> [SharedContainerImporter.ImportOutcome] {
        var processed = defaults.dictionary(forKey: processedKey) as? [String: Double] ?? [:]
        var outcomes: [SharedContainerImporter.ImportOutcome] = []

        for url in SharedContainerImporter.pendingFiles(in: directory, fileManager: fileManager) {
            let stamp = modificationStamp(for: url)
            guard processed[url.path] != stamp else { continue }
            do {
                let book = try library.importBook(from: url)
                outcomes.append(.init(url: url, importedBookID: book.id, error: nil))
                processed[url.path] = stamp
            } catch {
                outcomes.append(.init(url: url, importedBookID: nil, error: error.localizedDescription))
            }
        }
        defaults.set(processed, forKey: processedKey)
        return outcomes
    }

    private static func modificationStamp(for url: URL) -> Double {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSinceReferenceDate) ?? 0
    }
}
