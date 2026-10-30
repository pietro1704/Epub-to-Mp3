import Foundation

/// Joins book-owned artifacts and the retained job audio used by the reader.
struct BookDownloadStorage: Sendable {
    struct Entry: Sendable {
        let book: LocalAudioArtifactStore.DownloadedBook
        let jobID: String?
    }

    let artifacts: LocalAudioArtifactStore
    let retainedRoot: URL
    let downloads: AudiobookDownloads

    func entries(books: [BookEntity]) async throws -> [Entry] {
        let stored = try await artifacts.downloadedBooks()
        var result = Dictionary(uniqueKeysWithValues: stored.map { ($0.bookID, Entry(book: $0, jobID: nil)) })
        let jobCounts = Dictionary(grouping: books.compactMap(\.lastJobId), by: { $0 }).mapValues(\.count)
        for book in books {
            guard let jobID = book.lastJobId, jobCounts[jobID] == 1,
                  let directory = directory(jobID),
                  let manifest = try manifest(in: directory), manifest.jobId == jobID else { continue }
            let sizes = manifest.chapters.compactMap { chapter -> Int64? in
                guard isComponent(chapter.mp3FileName) else { return nil }
                let url = directory.appendingPathComponent("chapters").appendingPathComponent(chapter.mp3FileName)
                guard url.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/"),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, let size = values.fileSize, size > 0 else { return nil }
                return Int64(size)
            }
            guard !sizes.isEmpty else { continue }
            let previous = result[book.id]?.book
            result[book.id] = Entry(book: .init(bookID: book.id, title: book.title, author: book.author,
                chapterCount: sizes.count + (previous?.chapterCount ?? 0),
                byteCount: sizes.reduce(0, +) + (previous?.byteCount ?? 0)), jobID: jobID)
        }
        return result.values.sorted { $0.book.title.localizedCaseInsensitiveCompare($1.book.title) == .orderedAscending }
    }

    func remove(_ entry: Entry) async throws {
        if let jobID = entry.jobID {
            guard let directory = directory(jobID) else { throw CocoaError(.fileReadInvalidFileName) }
            try await downloads.withBookStorageMaintenance(jobId: jobID) {
                try Task.checkCancellation()
                if let manifest = try manifest(in: directory) {
                    guard manifest.jobId == jobID else { throw CocoaError(.fileReadCorruptFile) }
                    try FileManager.default.removeItem(at: directory)
                }
                try await artifacts.clearDownloadedAudio(bookID: entry.book.bookID)
            }
        } else {
            try Task.checkCancellation()
            try await artifacts.clearDownloadedAudio(bookID: entry.book.bookID)
        }
        NotificationCenter.default.post(name: LocalAudioArtifactStore.didChangeNotification, object: nil)
    }

    private func directory(_ jobID: String) -> URL? {
        guard isComponent(jobID) else { return nil }
        let root = retainedRoot.resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(jobID, isDirectory: true).resolvingSymlinksInPath()
        return directory.deletingLastPathComponent() == root ? directory : nil
    }

    private func isComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private func manifest(in directory: URL) throws -> AudiobookManifest? {
        let url = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(AudiobookManifest.self, from: Data(contentsOf: url))
    }
}
