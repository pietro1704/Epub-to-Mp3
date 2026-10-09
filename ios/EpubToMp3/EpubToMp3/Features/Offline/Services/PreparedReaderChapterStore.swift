import CryptoKit
import Foundation
import Darwin

/// Source-only chapter projection; style validation stays in PreparedChapterRenderer.
actor PreparedReaderChapterStore {
    struct Snapshot: Codable, Equatable, Sendable {
        let bookID: String
        let title: String?
        let author: String?
        let chapterOrdinal: Int
        let chapterCount: Int
        let chapter: EbookFulltext.Chapter
        let toc: [EbookFulltext.TocEntry]?
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
        let payload = try PropertyListDecoder().decode(EbookFulltext.self, from: bytes)
        guard payload.chapters.indices.contains(chapterOrdinal) else { throw PreparedChapterArchiveStore.StoreError.invalidKey }
        let snapshot = Snapshot(bookID: bookID, title: payload.bookTitle, author: payload.bookAuthor,
            chapterOrdinal: chapterOrdinal, chapterCount: payload.chapters.count,
            chapter: payload.chapters[chapterOrdinal], toc: payload.toc)
        guard valid(snapshot) else { throw PreparedChapterArchiveStore.StoreError.invalidKey }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try await archives.write(encoder.encode(snapshot), bookID: snapshot.bookID,
            chapterIndex: snapshot.chapterOrdinal, signature: binding.signature)
    }

    func read(bookID: String, chapterOrdinal: Int, fulltextURL: URL) async -> Snapshot? {
        do {
            let signature = try source(fulltextURL, collectBytes: false).signature
            guard let bytes = await archives.read(bookID: bookID, chapterIndex: chapterOrdinal, signature: signature),
                  let value = try? PropertyListDecoder().decode(Snapshot.self, from: bytes),
                  valid(value), value.bookID == bookID, value.chapterOrdinal == chapterOrdinal,
                  try source(fulltextURL, collectBytes: false).signature == signature else { return nil }
            return value
        } catch { return nil }
    }

    private func valid(_ value: Snapshot) -> Bool {
        !value.bookID.isEmpty && value.chapterCount > 0 && value.chapterOrdinal >= 0
            && value.chapterOrdinal < value.chapterCount && value.chapter.hasReadableContent
    }

    private func source(_ url: URL, collectBytes: Bool) throws -> (signature: String, bytes: Data) {
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
        var hash = SHA256()
        var count = 0
        var collected = Data()
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
            guard bytes.count <= maximumSourceBytes - count else {
                throw PreparedChapterArchiveStore.StoreError.oversized
            }
            count += bytes.count
            hash.update(data: bytes)
            if collectBytes { collected.append(bytes) }
        }
        guard Int64(count) == attributes.st_size else { throw PreparedChapterArchiveStore.StoreError.unsafeFile }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), collected)
    }
}
