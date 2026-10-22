import Foundation

/// Read-only projections; all mutations remain under LocalAudioArtifactStore.
struct LocalAudioStorageSummary {
    typealias DownloadedBook = LocalAudioArtifactStore.DownloadedBook
    let files: LocalAudioArtifactFiles
    private var fileManager: FileManager { files.fileManager }
    private var root: URL { files.root }

    func temporaryBookIDsEligibleForEviction() throws -> [String] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let bookDirectories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try bookDirectories.compactMap { directory in
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true,
                  let manifest = try files.loadManifest(at: directory) else {
                return nil
            }
            let hasTemporaryAudio = manifest.chapters.contains {
                $0.state == .available && $0.retention == .temporary
            }
            return hasTemporaryAudio ? manifest.bookID : nil
        }.sorted()
    }

    /// Lists books with audio explicitly kept by the user. Missing files are
    /// excluded so Settings never offers a destructive action for stale state.
    func downloadedBooks() throws -> [DownloadedBook] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return directories.compactMap { directory in
            guard let manifest = try? files.loadManifest(at: directory) else { return nil }
            let downloaded = manifest.chapters.filter {
                $0.retention == .downloaded
                    && $0.state == .available
                    && files.hasAudioFile(bookID: manifest.bookID, artifact: $0)
            }
            guard !downloaded.isEmpty else { return nil }
            return DownloadedBook(
                bookID: manifest.bookID,
                title: manifest.bookTitle,
                author: manifest.author,
                chapterCount: downloaded.count,
                byteCount: downloaded.reduce(Int64(0)) { $0 + $1.byteCount }
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

}
