import Foundation

struct LocalAudioArtifactFiles {
    typealias Manifest = LocalAudioArtifactStore.Manifest
    typealias ChapterArtifact = LocalAudioArtifactStore.ChapterArtifact
    let root: URL
    let fileManager: FileManager

    func loadManifest(bookID: String) throws -> Manifest? {
        try loadManifest(at: bookDirectory(bookID: bookID))
    }

    func loadManifest(at directory: URL) throws -> Manifest? {
        let url = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    func save(_ manifest: Manifest) throws {
        let directory = bookDirectory(bookID: manifest.bookID)
        try createDirectoryIfNeeded(directory)
        let url = directory.appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
        try applyManifestFilePolicy(to: url)
        NotificationCenter.default.post(
            name: LocalAudioArtifactStore.didChangeNotification,
            object: nil,
            userInfo: ["bookID": manifest.bookID]
        )
    }

    func bookDirectory(bookID: String) -> URL {
        root.appendingPathComponent(safePathComponent(bookID), isDirectory: true)
    }

    func chaptersDirectory(bookID: String) -> URL {
        bookDirectory(bookID: bookID).appendingPathComponent("chapters", isDirectory: true)
    }

    func relativePath(for chapterIndex: Int) -> String {
        "chapters/chapter-\(chapterIndex).mp3"
    }

    func hasAudioFile(bookID: String, artifact: ChapterArtifact) -> Bool {
        let url = bookDirectory(bookID: bookID).appendingPathComponent(artifact.relativePath)
        return ((try? fileSize(at: url)) ?? 0) > 0
    }

    func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    func createDirectoryIfNeeded(_ directory: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try applyPersistentFilePolicy(to: directory)
    }

    func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let normalized = raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let collapsed = normalized.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let safe = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return safe.isEmpty ? "book" : safe
    }

    func applyPersistentFilePolicy(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try applyFileProtection(to: url)
    }

    func applyFileProtection(to url: URL) throws {
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    func applyManifestFilePolicy(to url: URL) throws {
        try applyPersistentFilePolicy(to: url)
    }

    func applyTemporaryFilePolicy(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
        try applyFileProtection(to: url)
    }

    func applyDownloadedFilePolicy(to url: URL) throws {
        try applyPersistentFilePolicy(to: url)
    }

    func repairFilePolicies(for manifest: Manifest) throws {
        try createDirectoryIfNeeded(root)
        try createDirectoryIfNeeded(bookDirectory(bookID: manifest.bookID))
        try createDirectoryIfNeeded(chaptersDirectory(bookID: manifest.bookID))
        for artifact in manifest.chapters {
            let url = bookDirectory(bookID: manifest.bookID).appendingPathComponent(artifact.relativePath)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            switch artifact.retention {
            case .temporary:
                try applyTemporaryFilePolicy(to: url)
            case .downloaded:
                try applyDownloadedFilePolicy(to: url)
            }
        }
    }
}
