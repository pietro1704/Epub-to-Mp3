import CryptoKit
import Foundation
import Darwin

/// Source-only chapter projection; style validation stays in PreparedChapterRenderer.
actor PreparedReaderChapterStore {
    static let shared = PreparedReaderChapterStore()
    struct SourceIdentity: Codable, Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(value.st_dev)
            inode = UInt64(value.st_ino)
            size = value.st_size
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changedSeconds = Int64(value.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    struct Snapshot: Codable, Equatable, Sendable {
        struct CatalogChapter: Codable, Equatable, Sendable {
            let index: Int
            let name: String?
            let contentKind: String?
        }

        let bookID: String
        let title: String?
        let author: String?
        let chapterOrdinal: Int
        let chapterCount: Int
        let chapter: EbookFulltext.Chapter
        let toc: [EbookFulltext.TocEntry]?
        let catalogChapters: [CatalogChapter]?
        var sourceIdentity: SourceIdentity? = nil
        var sourceSignature: String? = nil

        private enum CodingKeys: String, CodingKey {
            case bookID, title, author, chapterOrdinal, chapterCount, chapter, toc, catalogChapters
            case sourceIdentity, sourceSignature
        }
    }

    private let archives: PreparedChapterArchiveStore
    private let maximumSourceBytes: Int

    init(directory: URL? = nil, fileManager: FileManager = .default,
         maximumSourceBytes: Int = 64 * 1024 * 1024) {
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EpubToMp3/PreparedReaderChapters-v1", isDirectory: true)
        archives = PreparedChapterArchiveStore(directory: root, fileManager: fileManager)
        self.maximumSourceBytes = maximumSourceBytes
    }

    func write(bookID: String, chapterOrdinal: Int, fulltextURL: URL) async throws {
        let binding = try source(fulltextURL, collectBytes: true)
        let bytes = binding.bytes
        try Task.checkCancellation()
        let payload = try PropertyListDecoder().decode(EbookFulltext.self, from: bytes)
        guard payload.chapters.indices.contains(chapterOrdinal) else { throw PreparedChapterArchiveStore.StoreError.invalidKey }
        let snapshot = Snapshot(bookID: bookID, title: payload.bookTitle, author: payload.bookAuthor,
            chapterOrdinal: chapterOrdinal, chapterCount: payload.chapters.count,
            chapter: payload.chapters[chapterOrdinal], toc: payload.toc,
            catalogChapters: payload.chapters.map {
                Snapshot.CatalogChapter(index: $0.index, name: $0.name, contentKind: $0.contentKind)
            }, sourceIdentity: binding.identity, sourceSignature: binding.signature)
        guard valid(snapshot) else { throw PreparedChapterArchiveStore.StoreError.invalidKey }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try Task.checkCancellation()
        let encoded = try encoder.encode(snapshot)
        try Task.checkCancellation()
        try await archives.write(encoded, bookID: snapshot.bookID,
            chapterIndex: snapshot.chapterOrdinal, signature: binding.signature)
    }

    func read(bookID: String, chapterOrdinal: Int, fulltextURL: URL) async -> Snapshot? {
        do {
            let initialIdentity = try sourceIdentity(fulltextURL)
            guard let record = await archives.read(bookID: bookID, chapterIndex: chapterOrdinal) else { return nil }
            try Task.checkCancellation()
            let archivedIdentity = try sourceIdentity(fulltextURL)
            guard archivedIdentity == initialIdentity,
                  var value = try? PropertyListDecoder().decode(Snapshot.self, from: record.archive),
                  valid(value), value.bookID == bookID, value.chapterOrdinal == chapterOrdinal else { return nil }

            if value.sourceIdentity != archivedIdentity || value.sourceSignature != record.signature {
                let scannedSource = try source(fulltextURL, collectBytes: false)
                guard record.signature == scannedSource.signature,
                      try sourceIdentity(fulltextURL) == scannedSource.identity else { return nil }
                value.sourceIdentity = scannedSource.identity
                value.sourceSignature = scannedSource.signature
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .binary
                let encoded = try encoder.encode(value)
                try Task.checkCancellation()
                try await archives.write(encoded, bookID: value.bookID,
                    chapterIndex: value.chapterOrdinal, signature: scannedSource.signature)
            } else {
                value.sourceIdentity = archivedIdentity
                value.sourceSignature = record.signature
            }

            guard try sourceIdentity(fulltextURL) == archivedIdentity else { return nil }
            try Task.checkCancellation()
            return value
        } catch { return nil }
    }

    nonisolated static func sourceMatches(_ snapshot: Snapshot, fulltextURL: URL) -> Bool {
        guard let expected = snapshot.sourceIdentity, fulltextURL.isFileURL else { return false }
        let descriptor = fulltextURL.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return false }
        return SourceIdentity(attributes) == expected
    }

    private func valid(_ value: Snapshot) -> Bool {
        !value.bookID.isEmpty && value.chapterCount > 0 && value.chapterOrdinal >= 0
            && value.chapterOrdinal < value.chapterCount && value.chapter.hasReadableContent
            && (value.catalogChapters.map { chapters in
                chapters.count == value.chapterCount
                    && chapters.allSatisfy { $0.index >= 0 }
            } ?? true)
    }

    private func sourceIdentity(_ url: URL) throws -> SourceIdentity {
        guard url.isFileURL else { throw PreparedChapterArchiveStore.StoreError.unsafeFile }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw PreparedChapterArchiveStore.StoreError.unsafeFile }
        defer { _ = close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size >= 0, attributes.st_size <= Int64(maximumSourceBytes) else {
            throw PreparedChapterArchiveStore.StoreError.unsafeFile
        }
        return SourceIdentity(attributes)
    }

    private func source(_ url: URL, collectBytes: Bool) throws -> (signature: String, bytes: Data, identity: SourceIdentity) {
        try Task.checkCancellation()
        guard url.isFileURL, maximumSourceBytes >= 0, maximumSourceBytes <= 256 * 1024 * 1024 else {
            throw PreparedChapterArchiveStore.StoreError.unsafeFile
        }
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw PreparedChapterArchiveStore.StoreError.unsafeFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size >= 0, attributes.st_size <= Int64(maximumSourceBytes) else {
            throw PreparedChapterArchiveStore.StoreError.unsafeFile
        }
        let initialIdentity = SourceIdentity(attributes)
        var hash = SHA256()
        var count = 0
        var collected = Data()
        while true {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty else { break }
            guard bytes.count <= maximumSourceBytes - count else {
                throw PreparedChapterArchiveStore.StoreError.oversized
            }
            count += bytes.count
            hash.update(data: bytes)
            if collectBytes { collected.append(bytes) }
        }
        try Task.checkCancellation()
        var finalAttributes = stat()
        guard Int64(count) == attributes.st_size, fstat(descriptor, &finalAttributes) == 0,
              SourceIdentity(finalAttributes) == initialIdentity else {
            throw PreparedChapterArchiveStore.StoreError.unsafeFile
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), collected, initialIdentity)
    }
}
