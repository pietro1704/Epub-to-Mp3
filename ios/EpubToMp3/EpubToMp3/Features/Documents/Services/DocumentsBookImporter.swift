import Foundation

/// Imports books placed in the app's Documents directory through Finder file
/// sharing. Source files stay in Documents; `LibraryStore` creates its own
/// durable copy in Application Support.
enum DocumentsBookImporter {
    private static let processedKey = "documents-book-importer.processed.v1"

    private struct PendingFile: Sendable {
        let url: URL
        let stamp: Double
    }

    @MainActor
    static func importPendingAsync(
        into library: LibraryStore, fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) async -> [SharedContainerImporter.ImportOutcome] {
        let resources = LibraryStore.ImportResources(fileManager: fileManager, defaults: defaults)
        guard let documents = try? await LibraryStore.performImportIO({
            try resources.fileManager.url(for: .documentDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
        }) else { return [] }
        return await importPendingAsync(in: documents, into: library,
                                        fileManager: fileManager, defaults: defaults)
    }

    @MainActor
    static func importPendingAsync(
        in directory: URL, into library: LibraryStore, fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) async -> [SharedContainerImporter.ImportOutcome] {
        let resources = LibraryStore.ImportResources(fileManager: fileManager, defaults: defaults)
        let pending: [PendingFile] = (try? await LibraryStore.performImportIO {
            let processed = resources.defaults?.dictionary(forKey: processedKey) as? [String: Double] ?? [:]
            return SharedContainerImporter.pendingFiles(in: directory, fileManager: resources.fileManager)
                .map { PendingFile(url: $0, stamp: modificationStamp(for: $0)) }
                .filter { processed[$0.url.path] != $0.stamp }
        }) ?? []
        let results = await library.importBooks(from: pending.map(\.url))
        let stamps = Dictionary(uniqueKeysWithValues: pending.map { ($0.url.path, $0.stamp) })
        let successful = results.filter { $0.book != nil }.map(\.url)
        _ = try? await LibraryStore.performImportIO {
            var processed = resources.defaults?.dictionary(forKey: processedKey) as? [String: Double] ?? [:]
            for url in successful { processed[url.path] = stamps[url.path] }
            resources.defaults?.set(processed, forKey: processedKey)
        }
        return results.map { .init(url: $0.url, importedBookID: $0.book?.id, error: $0.error) }
    }

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
