import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AudiobookChapterTransfer {
    // MARK: Network (nonisolated — stateless)

    static func downloadWithBackoff(url: URL, to destination: URL) async throws -> Int64 {
        let maxAttempts = 6
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            try Task.checkCancellation()
            attempt += 1
            do {
                return try await downloadOnce(url: url, to: destination)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                lastError = error
                let delaySeconds = min(30, pow(2.0, Double(attempt - 1)))
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    static func downloadOnce(url: URL, to destination: URL) async throws -> Int64 {
        try Task.checkCancellation()
        if url.isFileURL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let expectedBytes = (attributes[.size] as? Int64) ?? 0
            guard expectedBytes > 0 else { throw URLError(.cannotDecodeContentData) }
            let staged = destination.appendingPathExtension("local-partial")
            defer { try? FileManager.default.removeItem(at: staged) }
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.copyItem(at: url, to: staged)
            return try commitDownloadedFile(
                from: staged,
                to: destination,
                expectedBytes: expectedBytes
            )
        }
        let partial = destination.appendingPathExtension("partial")
        let existingBytes = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        let (tempURL, response) = try await AudiobookBackgroundTransfer.shared.download(
            from: Self.request(url: url, resumingAt: existingBytes)
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        if existingBytes > 0, statusCode == 206 {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(contentsOf: tempURL))
            try handle.close()
            guard let expectedBytes = Self.contentRangeTotal(from: response) else {
                throw URLError(.cannotDecodeContentData)
            }
            return try commitDownloadedFile(from: partial, to: destination, expectedBytes: expectedBytes)
        }
        // A server may ignore Range and return the complete object. Never
        // append that response to an existing partial file.
        try? FileManager.default.removeItem(at: partial)
        let expectedBytes = (response as? HTTPURLResponse)?.expectedContentLength ?? 0
        return try commitDownloadedFile(from: tempURL, to: destination, expectedBytes: expectedBytes)
    }

    /// Installs only a complete staged download. A partial artifact never
    /// replaces the user-visible MP3.
    static func commitDownloadedFile(
        from stagedFile: URL,
        to destination: URL,
        expectedBytes: Int64
    ) throws -> Int64 {
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: stagedFile.path)
        let bytes = (attributes[.size] as? Int64) ?? 0
        guard bytes > 0, expectedBytes <= 0 || bytes == expectedBytes else {
            throw URLError(.cannotDecodeContentData)
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: stagedFile, to: destination)
        return bytes
    }

    /// Builds the request used to resume a staged audiobook chapter.
    static func request(url: URL, resumingAt offset: Int64) -> URLRequest {
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        return request
    }

    /// Returns the complete object size from a `Content-Range` header such as
    /// `bytes 100-199/200`.
    static func contentRangeTotal(from response: URLResponse) -> Int64? {
        guard let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: "Content-Range") else { return nil }
        let total = value.split(separator: "/", maxSplits: 1).last.map(String.init)
        guard let total, total != "*" else { return nil }
        return Int64(total)
    }

    // MARK: Helpers (nonisolated — stateless)

    static func resolve(path: String, base: URL?) -> URL? {
        if path.lowercased().hasPrefix("file://") { return URL(string: path) }
        if path.lowercased().hasPrefix("http") { return URL(string: path) }
        if path.hasPrefix("/"), base == nil || base?.isFileURL == true {
            return URL(fileURLWithPath: path)
        }
        guard let base else { return nil }
        return URL(string: path, relativeTo: base)?.absoluteURL
    }

    static func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.isEmpty ? "chapter" : cleaned
        return String(trimmed.prefix(120))
    }
}
