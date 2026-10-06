// MacEpubParser.swift

#if os(macOS)

import Foundation

/// macOS document operations use the canonical HTTP backend. The local Rust
/// sidecar exposes the same upload/fulltext contract as the remote service.
enum MacEpubParser {
    static func parse(
        at fileURL: URL,
        client: APIClient,
        bookId: String
    ) async throws -> EbookFulltext {
        _ = bookId
        let uploadID = try await client.uploadBook(at: fileURL)
        return try await client.fetchUploadedFulltext(uploadID: uploadID)
    }
}

#endif
