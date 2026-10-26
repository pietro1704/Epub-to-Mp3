import Foundation
import CryptoKit

/// Durable intent for manual exports. Rust remains authoritative for audio reuse.
actor BookConversionRecoveryStore {
    static let shared = BookConversionRecoveryStore()

    struct Record: Codable, Equatable, Sendable {
        let bookID: String
        let jobID: String
        let options: ConversionOptions?
        var chaptersTotal: Int
        var completed: Set<Int>
        var interrupted: Bool
        var ancestors: [String]? = nil

        var resumeOptions: ConversionOptions {
            var next = options ?? ConversionOptions()
            next.recoveryJobID = jobID
            next.clearCache = false
            next.forceReprocess = false
            return next
        }
    }

    private let root: URL
    private var active: Set<String> = []

    init(root: URL = RustConversionOutputStore.defaultRoot) { self.root = root }

    func begin(bookURL: URL, jobID: String, options: ConversionOptions?) throws -> String {
        let bookID = try BookContentIdentity.hash(of: bookURL)
        let previous = try read(bookID)
        var capturedOptions = options
        if capturedOptions != nil, capturedOptions?.pronunciation == nil {
            capturedOptions?.pronunciation = BookPronunciationDictionary()
        }
        let continuesPrevious = options?.recoveryJobID.map { predecessor in
            previous?.jobID == predecessor || previous?.ancestors?.contains(predecessor) == true
        } ?? false
        var seen = Set<String>()
        let ancestors = (continuesPrevious
            ? [options!.recoveryJobID!, previous!.jobID] + (previous?.ancestors ?? []) : [])
            .filter { seen.insert($0).inserted }
        let record = Record(bookID: bookID, jobID: jobID, options: capturedOptions,
                            chaptersTotal: continuesPrevious ? previous?.chaptersTotal ?? 0 : 0,
                            completed: [], interrupted: false, ancestors: Array(ancestors.prefix(32)))
        try write(record)
        active.insert(jobID)
        return bookID
    }

    func progress(bookID: String, jobID: String, total: Int, completed: Int? = nil) throws {
        guard active.contains(jobID), var record = try read(bookID), record.jobID == jobID else { return }
        record.chaptersTotal = max(record.chaptersTotal, total)
        if let completed { record.completed.insert(completed) }
        try write(record)
    }

    func finish(bookID: String, jobID: String, succeeded: Bool) throws {
        active.remove(jobID)
        guard var record = try read(bookID), record.jobID == jobID else { return }
        if succeeded { try FileManager.default.removeItem(at: recordURL(bookID)) }
        else { record.interrupted = true; try write(record) }
    }

    func pending(bookID: String) throws -> Record? {
        guard var record = try read(bookID), !active.contains(record.jobID),
              UUID(uuidString: record.jobID) != nil else { return nil }
        guard ([record.jobID] + (record.ancestors ?? [])).contains(where: {
            UUID(uuidString: $0) != nil && FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }) else { return nil }
        var bestJobID = record.jobID
        var bestCompleted = try verifiedChapters(bookID: bookID, jobID: record.jobID)
        for ancestor in record.ancestors ?? [] where UUID(uuidString: ancestor) != nil {
            let completed = try verifiedChapters(bookID: bookID, jobID: ancestor)
            if completed.count > bestCompleted.count { bestJobID = ancestor; bestCompleted = completed }
        }
        record = Record(bookID: bookID, jobID: bestJobID, options: record.options,
                        chaptersTotal: record.chaptersTotal, completed: bestCompleted,
                        interrupted: true, ancestors: record.ancestors)
        return record
    }

    private func verifiedChapters(bookID: String, jobID: String) throws -> Set<Int> {
        let directory = root.appendingPathComponent(jobID)
        guard directory.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let ownerURL = directory.appendingPathComponent(".apple-output-owner.json")
        guard let ownerData = try? Data(contentsOf: ownerURL),
              let owner = try? JSONSerialization.jsonObject(with: ownerData) as? [String: Any],
              owner["bookID"] as? String == bookID, owner["jobID"] as? String == jobID else { return [] }
        // Count only audio whose current bytes match Rust's completion receipt.
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return Set(files.compactMap { file -> Int? in
                guard let ordinal = Int(file.lastPathComponent.prefix(4)), ordinal > 0 else { return nil }
                guard file.pathExtension == "mp3", let attributes = try? file.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                    attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                    let receipt = boundedReceipt(file.deletingPathExtension().appendingPathExtension("mp3.complete.json")),
                    let fields = try? JSONSerialization.jsonObject(with: receipt) as? [String: Any],
                    (fields["version"] as? Int) == 2,
                    (fields["size"] as? Int) == attributes.fileSize,
                    fields["audio_sha256"] as? String == streamingHash(file)
                else { return nil }
                // File ordinal belongs to the full manual-export selection.
                return ordinal - 1
        })
    }

    private func boundedReceipt(_ url: URL) -> Data? {
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              (attributes.fileSize ?? Int.max) <= 1_048_576 else { return nil }
        return try? Data(contentsOf: url)
    }

    private func streamingHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        do {
            while let bytes = try handle.read(upToCount: 262_144), !bytes.isEmpty { hash.update(data: bytes) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        } catch { return nil }
    }

    private func recordURL(_ bookID: String) throws -> URL {
        guard bookID.count == 32, bookID.allSatisfy(\.isHexDigit) else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = root.appendingPathComponent(".recovery")
        guard directory.resolvingSymlinksInPath() == directory.standardizedFileURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return directory.appendingPathComponent(bookID + ".json")
    }

    private func read(_ bookID: String) throws -> Record? {
        let url = try recordURL(bookID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.bookID == bookID else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    private func write(_ record: Record) throws {
        let url = try recordURL(record.bookID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
}
