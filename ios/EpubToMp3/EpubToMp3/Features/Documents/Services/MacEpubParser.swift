// MacEpubParser.swift

#if os(macOS)

import Foundation

/// macOS entry point for the same in-process EPUB parser used by iOS.
/// Keeping this adapter small prevents a second parser or a child Python
/// process from diverging from the native reader path.
enum MacEpubParser {
    static func parse(at fileURL: URL, bookId: String) async throws -> EbookFulltext {
        try await PythonBridge.shared.parseEpub(at: fileURL, bookId: bookId)
    }
}

#endif
