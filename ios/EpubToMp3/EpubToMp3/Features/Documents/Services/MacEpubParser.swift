// MacEpubParser.swift

#if os(macOS)

import Foundation

/// macOS document operations parse locally and never require a backend.
enum MacEpubParser {
    static func parse(
        at fileURL: URL,
        bookId: String
    ) async throws -> EbookFulltext {
        return await EpubFallbackParser.parseAsync(url: fileURL, bookId: bookId)
    }
}

#endif
