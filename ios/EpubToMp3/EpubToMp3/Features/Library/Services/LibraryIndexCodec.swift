import Foundation

enum LibraryIndexCodec {
    /// Outcome of the persisted-library decode.
    enum DecodeOutcome: Sendable {
        case success((books: [BookEntity], needsPersist: Bool))
        case failure(String)
        case empty
    }

    /// Single decode + migrate pipeline shared by both load paths.
    static func decode(data: Data?) -> DecodeOutcome {
        guard let data else { return .empty }
        do {
            let decoded = try JSONDecoder().decode([BookEntity].self, from: data)
            let pruned = decoded.filter { !$0.bookmark.isEmpty }
            var migrated = false
            var result = pruned
            for i in result.indices {
                if let author = result[i].author,
                   Self.isParserErrorText(author) {
                    result[i].author = nil
                    migrated = true
                }
                if let cover = result[i].coverPNG,
                   cover.count > LibraryCoverThumbnail.coverMaxBytes {
                    result[i].coverPNG = LibraryCoverThumbnail.downsampleCover(cover)
                    migrated = true
                }
            }
            return .success((result, pruned.count != decoded.count || migrated))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func isParserErrorText(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("parse timed out")
            || normalized.contains("python parser")
            || normalized.contains("failed to parse epub")
            || normalized.hasPrefix("reader.")
            || normalized.hasPrefix("bookopen.")
    }

}
