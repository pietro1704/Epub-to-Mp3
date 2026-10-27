import Foundation

/// Transport checkpoints never authorize installation. Rust verifies the full artifact.
struct SpeechModelRangeDownload {
    static let chunkBytes: UInt64 = 4 * 1024 * 1024
    static let maximumRetries = 2

    struct Request: Codable {
        let descriptor: SpeechModelTransferDescriptor
        let sourceURL: URL
        let offset: UInt64
        let validator: String?
        let fullDownload: Bool
        let retryCount: Int

        var urlRequest: URLRequest {
            var request = URLRequest(url: sourceURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if !fullDownload, descriptor.expectedBytes > offset {
                let remaining = descriptor.expectedBytes - offset
                let end = offset + min(remaining, SpeechModelRangeDownload.chunkBytes) - 1
                request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
                if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
            }
            return request
        }

        func encoded() throws -> String {
            String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        }

        static func decode(_ value: String?) -> Self? {
            value.flatMap { try? JSONDecoder().decode(Self.self, from: Data($0.utf8)) }
        }
    }

    enum Outcome {
        case next(Request)
        case complete
    }

    private struct Checkpoint: Codable {
        let version: Int
        let descriptor: SpeechModelTransferDescriptor
        let sourceURL: URL
        let validator: String
        let committedBytes: UInt64
    }

    let descriptor: SpeechModelTransferDescriptor
    let sourceURL: URL

    private var inbox: URL { URL(fileURLWithPath: descriptor.inboxPath) }
    private var partial: URL { inbox.appendingPathExtension("partial") }
    private var receipt: URL { inbox.appendingPathExtension("range.json") }

    func initialRequest(retryCount: Int = 0) throws -> Request? {
        try prepareDirectory()
        if let checkpoint = try recoverCheckpoint() {
            if checkpoint.committedBytes == descriptor.expectedBytes {
                try replaceInbox(with: partial)
                try removeOwnedFile(receipt)
                return nil
            }
            return request(
                offset: checkpoint.committedBytes,
                validator: checkpoint.validator,
                retryCount: retryCount
            )
        }
        return request(retryCount: retryCount)
    }

    /// A received 206 proves range support; advertising Accept-Ranges alone does not.
    func accept(response: HTTPURLResponse, file: URL, request: Request) throws -> Outcome {
        guard request.descriptor == descriptor, request.sourceURL == sourceURL,
              response.url?.scheme?.lowercased() == "https" else {
            throw URLError(.badServerResponse)
        }
        try prepareDirectory()
        if response.statusCode == 200 {
            // If-Range mismatch and ignored Range both return the full representation.
            // Replace the prefix; appending this response would duplicate bytes.
            try discardCheckpoint()
            try replaceInbox(with: file)
            return .complete
        }
        guard response.statusCode == 206, !request.fullDownload,
              let range = contentRange(response),
              range.start == request.offset,
              range.total == descriptor.expectedBytes,
              range.end - range.start < Self.chunkBytes,
              let validator = strongETag(response),
              request.validator == nil || request.validator == validator,
              response.value(forHTTPHeaderField: "Content-Encoding").map({
                  $0.lowercased() == "identity"
              }) ?? true,
              try regularFileSize(file) == range.end - range.start + 1 else {
            return try restartFully(after: request)
        }
        if request.offset == 0 {
            try discardCheckpoint()
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                throw URLError(.cannotCreateFile)
            }
        } else {
            guard let checkpoint = try recoverCheckpoint(),
                  checkpoint.committedBytes == request.offset,
                  checkpoint.validator == validator else {
                return try restartFully(after: request)
            }
        }
        try append(file, to: partial)
        let committed = range.end + 1
        let checkpoint = Checkpoint(
            version: 1, descriptor: descriptor, sourceURL: sourceURL,
            validator: validator, committedBytes: committed
        )
        // Sync the prefix before atomically publishing its committed length.
        try JSONEncoder().encode(checkpoint).write(to: receipt, options: .atomic)
        if committed == descriptor.expectedBytes {
            try replaceInbox(with: partial)
            try removeOwnedFile(receipt)
            return .complete
        }
        return .next(self.request(
            offset: committed, validator: validator, retryCount: request.retryCount
        ))
    }

    func retry(after error: Error, request: Request) throws -> Request? {
        let error = error as NSError
        let transientCodes = [
            NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
            NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
        ]
        guard error.domain == NSURLErrorDomain, transientCodes.contains(error.code),
              request.retryCount < Self.maximumRetries else { return nil }
        if request.fullDownload {
            return self.request(fullDownload: true, retryCount: request.retryCount + 1)
        }
        return try initialRequest(retryCount: request.retryCount + 1)
    }

    func discardCheckpoint() throws {
        try removeOwnedFile(partial)
        try removeOwnedFile(receipt)
    }

    private func restartFully(after previous: Request) throws -> Outcome {
        guard !previous.fullDownload else { throw URLError(.badServerResponse) }
        try discardCheckpoint()
        return .next(request(fullDownload: true, retryCount: previous.retryCount))
    }

    private func request(
        offset: UInt64 = 0, validator: String? = nil,
        fullDownload: Bool = false, retryCount: Int = 0
    ) -> Request {
        Request(
            descriptor: descriptor, sourceURL: sourceURL, offset: offset,
            validator: validator, fullDownload: fullDownload, retryCount: retryCount
        )
    }

    private func recoverCheckpoint() throws -> Checkpoint? {
        guard let receiptBytes = try? regularFileSize(receipt), receiptBytes <= 64 * 1024,
              let checkpoint = try? JSONDecoder().decode(
                  Checkpoint.self, from: Data(contentsOf: receipt)
              ),
              checkpoint.version == 1, checkpoint.descriptor == descriptor,
              checkpoint.sourceURL == sourceURL, isStrongETag(checkpoint.validator),
              checkpoint.committedBytes > 0,
              checkpoint.committedBytes <= descriptor.expectedBytes,
              let length = try? regularFileSize(partial), length >= checkpoint.committedBytes,
              length <= descriptor.expectedBytes,
              length - checkpoint.committedBytes <= Self.chunkBytes else {
            try discardCheckpoint()
            return nil
        }
        if length > checkpoint.committedBytes {
            // A process can die after append but before the receipt rename commits.
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try handle.truncate(atOffset: checkpoint.committedBytes)
            try handle.synchronize()
        }
        return checkpoint
    }

    private func prepareDirectory() throws {
        guard sourceURL.scheme?.lowercased() == "https",
              descriptor.expectedBytes > 0 else { throw URLError(.badURL) }
        _ = try descriptor.validatedInboxURL()
        let directory = inbox.deletingLastPathComponent()
        for ownedDirectory in [URL(fileURLWithPath: descriptor.modelRoot), directory] {
            if FileManager.default.fileExists(atPath: ownedDirectory.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: ownedDirectory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw URLError(.noPermissionsToReadFile)
                }
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func contentRange(_ response: HTTPURLResponse) -> (start: UInt64, end: UInt64, total: UInt64)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes ") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard bounds.count == 2, let total = UInt64(bounds[1]) else { return nil }
        let offsets = bounds[0].split(separator: "-", omittingEmptySubsequences: false)
        guard offsets.count == 2, let start = UInt64(offsets[0]), let end = UInt64(offsets[1]),
              start <= end, end < total else { return nil }
        return (start, end, total)
    }

    private func strongETag(_ response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "ETag").flatMap { isStrongETag($0) ? $0 : nil }
    }

    private func isStrongETag(_ value: String) -> Bool {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return false }
        return value.dropFirst().dropLast().utf8.allSatisfy { $0 == 0x21 || $0 >= 0x23 && $0 != 0x7f }
    }

    private func regularFileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw URLError(.noPermissionsToReadFile)
        }
        return size.uint64Value
    }

    private func removeOwnedFile(_ url: URL) throws {
        // Unlink a symlink itself; never traverse it or remove an unexpected directory.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        guard attributes[.type] as? FileAttributeType != .typeDirectory else {
            throw URLError(.noPermissionsToReadFile)
        }
        try FileManager.default.removeItem(at: url)
    }

    private func replaceInbox(with source: URL) throws {
        try removeOwnedFile(inbox)
        try FileManager.default.moveItem(at: source, to: inbox)
    }

    private func append(_ source: URL, to destination: URL) throws {
        _ = try regularFileSize(destination)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.seekToEnd()
        while let bytes = try input.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
    }
}
