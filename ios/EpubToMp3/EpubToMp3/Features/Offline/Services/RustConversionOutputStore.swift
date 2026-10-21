import Foundation
import Darwin

/// Owns Rust output identities and keeps explicit deletion behind live writers.
/// Unknown legacy directories are counted but never guessed to belong to a book.
actor RustConversionOutputStore {
    enum StorageError: LocalizedError {
        case unrecognizedOutputs(Int)
        var errorDescription: String? {
            switch self {
            case .unrecognizedOutputs(let count):
                return L10n.string("settings.storageUnrecognizedAudioMessage", count)
            }
        }
    }
    static let shared = RustConversionOutputStore()
    nonisolated static let willRemoveAudio = Notification.Name("epub2mp3.rustConversionWillRemoveAudio")
    nonisolated static let defaultRoot = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .resolvingSymlinksInPath()
        .appendingPathComponent("EpubToMp3/RustConversions", isDirectory: true)

    struct Lease: Sendable {
        let id: UUID
        let jobID: String
        let outputDirectory: URL
    }

    private struct Ownership: Codable {
        let version: Int
        let bookID: String
        let jobID: String
    }

    private struct Writer {
        let lease: Lease
        let bookID: String
        let cancel: @Sendable () -> Void
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let root: URL
    private let notificationCenter: NotificationCenter
    private let bookIdentity: @Sendable (URL) async throws -> String
    private var writers: [String: Writer] = [:]
    private var maintaining = false
    private var maintenanceEpoch: UInt64 = 0
    private static let ownerFilename = ".apple-output-owner.json"

    init(root: URL = defaultRoot, notificationCenter: NotificationCenter = .default,
         bookIdentity: @escaping @Sendable (URL) async throws -> String = { url in
             try await Task.detached(priority: .utility) { try BookContentIdentity.hash(of: url) }.value
         }) {
        self.root = root
        self.notificationCenter = notificationCenter
        self.bookIdentity = bookIdentity
    }

    func begin(bookURL: URL, jobID: String, cancel: @escaping @Sendable () -> Void) async throws -> Lease {
        guard !maintaining else { throw CocoaError(.fileWriteFileExists) }
        let epoch = maintenanceEpoch
        let bookID = try await bookIdentity(bookURL)
        try Task.checkCancellation()
        guard epoch == maintenanceEpoch else { throw CancellationError() }
        return try begin(bookID: bookID, jobID: jobID, cancel: cancel)
    }

    /// The hash-taking overload also keeps storage fixtures independent of EPUB parsing.
    func begin(bookID: String, jobID: String, cancel: @escaping @Sendable () -> Void) throws -> Lease {
        try Task.checkCancellation()
        guard !bookID.isEmpty, !maintaining, writers[jobID] == nil else { throw CocoaError(.fileWriteFileExists) }
        let directory = try jobDirectory(jobID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try validateRoot()
        // This is new-job creation, never an implicit resume. mkdir reserves the
        // directory atomically even if an independent store uses the same root.
        let reserved = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        guard reserved == 0 else {
            let failure = errno
            if failure == EEXIST { throw CocoaError(.fileWriteFileExists) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        let identity = Ownership(version: 1, bookID: bookID, jobID: jobID)
        try JSONEncoder().encode(identity).write(to: directory.appendingPathComponent(Self.ownerFilename), options: .atomic)
        let lease = Lease(id: UUID(), jobID: jobID, outputDirectory: directory)
        writers[jobID] = Writer(lease: lease, bookID: bookID, cancel: cancel)
        return lease
    }

    func finish(_ lease: Lease) {
        guard let writer = writers[lease.jobID], writer.lease.id == lease.id else { return }
        writers.removeValue(forKey: lease.jobID)
        writer.waiters.forEach { $0.resume() }
    }

    /// All Rust outputs are protected audio; temporary-cache cleanup never visits this root.
    nonisolated static func storageBytes(at root: URL = defaultRoot) -> Int64 {
        guard hasCanonicalRoot(root) else { return 0 }
        guard let files = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { total, item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return total }
            return total + Int64(values.fileSize ?? 0)
        }
    }

    func clearAllAudio(afterRemoval: @Sendable () async throws -> Void = {}) async throws {
        try await removeAudio(bookID: nil, legacyJobID: nil, afterRemoval: afterRemoval)
    }

    func removeAudio(bookID: String, legacyJobID: String? = nil,
                     afterRemoval: @Sendable () async throws -> Void = {}) async throws {
        try await removeAudio(bookID: Optional(bookID), legacyJobID: legacyJobID, afterRemoval: afterRemoval)
    }

    private func removeAudio(bookID: String?, legacyJobID: String?,
                             afterRemoval: @Sendable () async throws -> Void) async throws {
        guard !maintaining else { throw CocoaError(.fileWriteFileExists) }
        maintaining = true
        maintenanceEpoch &+= 1
        defer { maintaining = false }
        try Task.checkCancellation()
        try validateRoot()
        let center = notificationCenter
        await MainActor.run {
            center.post(name: Self.willRemoveAudio, object: nil,
                        userInfo: bookID.map { ["bookID": $0] })
        }
        let active = writers.values.filter { bookID == nil || $0.bookID == bookID }
        active.forEach { $0.cancel() }
        for writer in active {
            await waitForWriter(writer.lease)
        }
        try Task.checkCancellation()
        var unrecognized = 0
        for directory in try directories() {
            let identity = ownership(at: directory)
            let knownLegacy = directory.lastPathComponent == legacyJobID && validLegacyManifest(at: directory)
            let migratedBookID = identity == nil ? await legacyBookID(at: directory) : nil
            let selected = bookID == nil
                ? identity != nil || validLegacyManifest(at: directory)
                : identity?.bookID == bookID || migratedBookID == bookID
                    || (identity == nil && migratedBookID == nil && knownLegacy)
            guard selected else {
                if bookID == nil { unrecognized += 1 }
                continue
            }
            try Task.checkCancellation()
            try validateRoot()
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            try FileManager.default.removeItem(at: directory)
            let record = root.appendingPathComponent(".jobs", isDirectory: true)
                .appendingPathComponent(directory.lastPathComponent + ".json")
            if regularMetadata(at: record) { try FileManager.default.removeItem(at: record) }
        }
        try await afterRemoval()
        if unrecognized > 0 { throw StorageError.unrecognizedOutputs(unrecognized) }
    }

    private func waitForWriter(_ lease: Lease) async {
        guard writers[lease.jobID]?.lease.id == lease.id else { return }
        await withCheckedContinuation { continuation in
            writers[lease.jobID]?.waiters.append(continuation)
        }
    }

    private func jobDirectory(_ jobID: String) throws -> URL {
        try validateRoot()
        guard !jobID.isEmpty, !jobID.hasPrefix("."),
              !jobID.contains("/"), !jobID.contains("\\"), !jobID.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let directory = root.appendingPathComponent(jobID, isDirectory: true)
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return directory
    }

    private func directories() throws -> [URL] {
        try validateRoot()
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter {
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
            }
    }

    private func ownership(at directory: URL) -> Ownership? {
        let file = directory.appendingPathComponent(Self.ownerFilename)
        guard regularMetadata(at: file), let data = try? Data(contentsOf: file),
              let identity = try? JSONDecoder().decode(Ownership.self, from: data),
              identity.version == 1, identity.jobID == directory.lastPathComponent,
              !identity.bookID.isEmpty else { return nil }
        return identity
    }

    private func validLegacyManifest(at directory: URL) -> Bool {
        let file = directory.appendingPathComponent("manifest.json")
        guard regularMetadata(at: file), let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["jobId"] as? String == directory.lastPathComponent,
              json["chapters"] is [[String: Any]] else { return false }
        return true
    }

    private func validateRoot() throws {
        guard Self.hasCanonicalRoot(root) else { throw CocoaError(.fileReadInvalidFileName) }
    }

    nonisolated private static func hasCanonicalRoot(_ root: URL) -> Bool {
        // Foundation canonicalizes /private/var back to /var on Darwin, even
        // after resolvingSymlinksInPath(). Accept only that system alias;
        // custom aliases in the root or any ancestor remain forbidden.
        var ancestor = root.standardizedFileURL
        while ancestor.path != "/" {
            if (try? ancestor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                guard ancestor.path == "/var",
                      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path),
                      destination == "private/var" || destination == "/private/var" else {
                    return false
                }
            }
            ancestor.deleteLastPathComponent()
        }
        return true
    }

    private func regularMetadata(at file: URL) -> Bool {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        // A regular file under a symlinked .jobs directory is not an owned receipt.
        return (try? file.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    }

    private func legacyBookID(at directory: URL) async -> String? {
        let record = root.appendingPathComponent(".jobs", isDirectory: true)
            .appendingPathComponent(directory.lastPathComponent + ".json")
        guard regularMetadata(at: record), let data = try? Data(contentsOf: record),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["job_id"] as? String == directory.lastPathComponent,
              let metadata = json["metadata"] as? [String: Any],
              let path = metadata["input"] as? String, path.hasPrefix("/") else { return nil }
        let source = URL(fileURLWithPath: path)
        return await Task.detached(priority: .utility) {
            try? BookContentIdentity.hash(of: source)
        }.value
    }
}
