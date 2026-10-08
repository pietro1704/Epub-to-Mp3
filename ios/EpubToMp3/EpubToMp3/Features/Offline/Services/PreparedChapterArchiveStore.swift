import CryptoKit
import Foundation

/// Stores opaque secure-archive bytes. Creation and decoding belong to the caller's MainActor.
actor PreparedChapterArchiveStore {
    static let maximumFileBytes = 8 * 1024 * 1024
    enum StoreError: Error { case invalidKey, unsafeFile, oversized, budgetExceeded }
    private struct Envelope: Codable {
        let schema: Int
        let bookID: String
        let chapterIndex: Int
        let signature: String
        let archive: Data
    }
    private let directory: URL
    private let totalBudgetBytes: Int?
    private let manager: FileManager

    init(directory: URL? = nil, totalBudgetBytes: Int? = 64 * 1024 * 1024, fileManager: FileManager = .default) {
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EpubToMp3/PreparedChapters-v1", isDirectory: true)
        self.totalBudgetBytes = totalBudgetBytes
        self.manager = fileManager
    }

    func read(bookID: String, chapterIndex: Int, signature: String) -> Data? {
        do {
            let target = try targetURL(bookID: bookID, chapterIndex: chapterIndex, signature: signature)
            try validateRoot(create: false)
            let size = try regularFileSize(target)
            guard size <= Self.maximumFileBytes else { return nil }
            let handle = try FileHandle(forReadingFrom: target)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
            guard bytes.count <= Self.maximumFileBytes else { return nil }
            let envelope = try PropertyListDecoder().decode(Envelope.self, from: bytes)
            guard envelope.schema == 1, envelope.bookID == bookID,
                  envelope.chapterIndex == chapterIndex, envelope.signature == signature,
                  envelope.archive.count <= Self.maximumFileBytes else { return nil }
            return envelope.archive
        } catch { return nil }
    }

    func write(_ archive: Data, bookID: String, chapterIndex: Int, signature: String) throws {
        guard archive.count <= Self.maximumFileBytes else { throw StoreError.oversized }
        let target = try targetURL(bookID: bookID, chapterIndex: chapterIndex, signature: signature)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let bytes = try encoder.encode(Envelope(schema: 1, bookID: bookID, chapterIndex: chapterIndex,
                                               signature: signature, archive: archive))
        guard bytes.count <= Self.maximumFileBytes else { throw StoreError.oversized }
        try validateRoot(create: true)
        let oldSize = try existingRegularFileSize(target) ?? 0
        if let budget = totalBudgetBytes {
            guard budget >= 0 else { throw StoreError.budgetExceeded }
            var used = 0
            for entry in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let size = try regularFileSize(entry)
                guard size <= budget - used else { throw StoreError.budgetExceeded }
                used += size
            }
            guard bytes.count <= budget - (used - oldSize) else { throw StoreError.budgetExceeded }
        }
        try bytes.write(to: target, options: .atomic)
    }

    /// Removes only this book/chapter's archive, never a directory or another book.
    func remove(bookID: String, chapterIndex: Int) throws {
        let target = try targetURL(bookID: bookID, chapterIndex: chapterIndex,
                                   signature: String(repeating: "0", count: 64))
        try validateRoot(create: false)
        if try existingRegularFileSize(target) != nil { try manager.removeItem(at: target) }
    }

    private func targetURL(bookID: String, chapterIndex: Int, signature: String) throws -> URL {
        guard !bookID.isEmpty, bookID.utf8.count <= 1024, chapterIndex >= 0, signature.utf8.count == 64,
              signature.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw StoreError.invalidKey
        }
        let digest = SHA256.hash(data: Data(bookID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest)-\(chapterIndex).archive")
    }

    private func validateRoot(create: Bool) throws {
        do {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StoreError.unsafeFile }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            guard create else { throw error }
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try validateRoot(create: false)
        }
    }

    private func existingRegularFileSize(_ url: URL) throws -> Int? {
        do { return try regularFileSize(url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        }
    }

    private func regularFileSize(_ url: URL) throws -> Int {
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= Int64(Int.max) else { throw StoreError.unsafeFile }
        return size.intValue
    }
}
