import Foundation

/// Copies of downloaded chapters where the listener can see them in the Files
/// app: `<root>/<Book title>/<NN> - <Chapter title>.mp3`.
///
/// `LocalAudioArtifactStore` stays the source of truth and nothing reads this
/// folder back. Each book folder carries a hidden index of the files this type
/// created, so a removal only ever deletes those files: anything the listener
/// put, renamed or copied there is left alone, and a copy the listener deleted
/// is not recreated until that chapter is downloaded again.
struct DownloadedAudioFilesMirror: Sendable {
    let root: URL

    static let indexFileName = ".downloads.json"

    /// The folder the Files app shows on iPhone and iPad. The Mac keeps app
    /// audio inside its container, where the listener has no such folder.
    static var userVisible: DownloadedAudioFilesMirror? {
        #if os(iOS)
        DownloadedAudioFilesMirror(root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audiobooks", isDirectory: true))
        #else
        nil
        #endif
    }

    private struct Index: Codable {
        var bookID: String
        /// Store chapter index -> file name inside the book folder.
        var files: [String: String]
        /// Preview builds recorded names without file identity.
        var identities: [String: CopyIdentity]?
    }

    private struct CopyIdentity: Codable, Equatable {
        let fileNumber: UInt64
        let digest: Data

        init(file: URL, under root: URL, knownDigest: Data? = nil) throws {
            try LocalAudioImportFiles.requireRegularFile(file, under: root)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard let fileNumber = attributes[.systemFileNumber] as? NSNumber else {
                throw CocoaError(.fileReadUnknown)
            }
            self.fileNumber = fileNumber.uint64Value
            digest = try knownDigest ?? Data(LocalAudioImportFiles.fingerprint(file).digest)
        }
    }

    /// Publishes one chapter. The copy is an APFS clone on the same volume.
    func publish(
        _ audio: URL, bookID: String, bookTitle: String, chapterIndex: Int, chapterTitle: String,
        expectedDigest: Data? = nil
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try existingFolder(bookID: bookID) ?? newFolder(bookTitle: bookTitle)
        var index = loadIndex(in: folder, bookID: bookID) ?? Index(bookID: bookID, files: [:])
        let key = String(chapterIndex)
        let previous = ownedCopy(key, in: index, folder: folder)
        if let expectedDigest, previous != nil, index.identities?[key]?.digest == expectedDigest {
            return
        }
        let staging = folder.appendingPathComponent(".publish-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: audio, to: staging)
        let identity = try CopyIdentity(file: staging, under: folder)
        if let expectedDigest, identity.digest != expectedDigest {
            throw LocalAudioImportFiles.Failure.sourceChanged
        }
        let title = Self.component(chapterTitle, fallback: L10n.fallbackChapterName(chapterIndex + 1))
        let name = Self.freeName(
            String(format: "%02d - %@", chapterIndex + 1, title), fileExtension: "mp3",
            in: folder, reusing: previous?.lastPathComponent)
        let destination = folder.appendingPathComponent(name)
        if destination.path == previous?.path {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging, options: .usingNewMetadataOnly)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        let oldIndex = index
        index.files[key] = name
        index.identities = index.identities ?? [:]
        index.identities?[key] = try CopyIdentity(file: destination, under: folder, knownDigest: identity.digest)
        try save(index, in: folder)
        if previous?.path != destination.path {
            try removeOwnedCopy(key, in: oldIndex, folder: folder)
        }
    }

    func publishedChapterIndices(bookID: String) -> Set<Int> {
        guard let folder = try? existingFolder(bookID: bookID),
              let index = loadIndex(in: folder, bookID: bookID) else { return [] }
        return Set(index.files.compactMap { entry in
            guard let chapter = Int(entry.key), Self.isComponent(entry.value),
                  let values = try? folder.appendingPathComponent(entry.value).resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? 0) > 0 else { return nil }
            return chapter
        })
    }

    /// Removes the copy of one chapter, and the book folder once nothing is left in it.
    func withdraw(bookID: String, chapterIndex: Int) throws {
        guard let folder = try existingFolder(bookID: bookID),
              var index = loadIndex(in: folder, bookID: bookID) else { return }
        let key = String(chapterIndex)
        try removeOwnedCopy(key, in: index, folder: folder)
        index.files[key] = nil
        index.identities?[key] = nil
        try finish(index, in: folder)
    }

    func withdrawBook(bookID: String) throws {
        guard let folder = try existingFolder(bookID: bookID),
              var index = loadIndex(in: folder, bookID: bookID) else { return }
        try withdrawCopies(&index, in: folder)
    }

    func withdrawAll() throws {
        for folder in try folders() {
            guard var index = loadIndex(in: folder, bookID: nil) else { continue }
            try withdrawCopies(&index, in: folder)
        }
    }

    private func withdrawCopies(_ index: inout Index, in folder: URL) throws {
        for key in index.files.keys {
            try removeOwnedCopy(key, in: index, folder: folder)
        }
        index.files.removeAll()
        index.identities?.removeAll()
        try finish(index, in: folder)
    }

    private func ownedCopy(_ key: String, in index: Index, folder: URL) -> URL? {
        guard let name = index.files[key], Self.isComponent(name),
              let expected = index.identities?[key] else { return nil }
        let url = folder.appendingPathComponent(name)
        guard (try? CopyIdentity(file: url, under: folder)) == expected else { return nil }
        return url
    }

    private func removeOwnedCopy(_ key: String, in index: Index, folder: URL) throws {
        guard let url = ownedCopy(key, in: index, folder: folder) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// True for a folder this type created; storage accounting skips those,
    /// because their files are clones of audio the store already counts.
    static func isMirrorFolder(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(indexFileName).path)
    }

    // MARK: Folders and index

    private func folders() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).filter {
            let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
    }

    private func existingFolder(bookID: String) throws -> URL? {
        try folders().first { loadIndex(in: $0, bookID: bookID) != nil }
    }

    private func newFolder(bookTitle: String) throws -> URL {
        let name = Self.freeName(Self.component(bookTitle, fallback: "Audiobook"), fileExtension: nil, in: root)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// The folder's index, when it is a regular file and belongs to `bookID` (any book when nil).
    private func loadIndex(in folder: URL, bookID: String?) -> Index? {
        let url = folder.appendingPathComponent(Self.indexFileName)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(Index.self, from: data),
              bookID == nil || index.bookID == bookID else { return nil }
        return index
    }

    private func save(_ index: Index, in folder: URL) throws {
        try JSONEncoder().encode(index).write(
            to: folder.appendingPathComponent(Self.indexFileName), options: .atomic)
    }

    /// Persists the index, or removes it and the folder when no copy is left.
    /// A folder that still holds the listener's own files stays.
    private func finish(_ index: Index, in folder: URL) throws {
        guard index.files.isEmpty else { return try save(index, in: folder) }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder.appendingPathComponent(Self.indexFileName))
        if (try? fileManager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? fileManager.removeItem(at: folder)
        }
    }

    // MARK: Names

    static func isComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.hasPrefix(".")
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    /// One readable path component from a title: separators and characters the
    /// Files app or other systems reject become spaces, and the length is bounded.
    static func component(_ title: String, fallback: String) -> String {
        let rejected = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.controlCharacters).union(.newlines)
        let cleaned = String(String.UnicodeScalarView(title.unicodeScalars.map { rejected.contains($0) ? " " : $0 }))
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        var bounded = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        while bounded.utf8.count > 180 { bounded.removeLast() }
        return bounded.isEmpty ? fallback : bounded
    }

    /// `base` with its extension, or `base (2)`, `base (3)`… when the name is taken.
    private static func freeName(
        _ base: String, fileExtension: String?, in directory: URL, reusing existingName: String? = nil
    ) -> String {
        func name(_ attempt: Int) -> String {
            let stem = attempt == 1 ? base : "\(base) (\(attempt))"
            return fileExtension.map { "\(stem).\($0)" } ?? stem
        }
        var attempt = 1
        while name(attempt) != existingName,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent(name(attempt)).path) {
            attempt += 1
        }
        return name(attempt)
    }
}
