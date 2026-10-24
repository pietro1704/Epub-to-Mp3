import Foundation

/// A reader position and a Rust structure position are different coordinate
/// systems. Only the source document identity can connect them reliably.
struct ReaderConversionChapterMap: Codable, Sendable {
    let coreToReader: [Int: Int]
    let coreTextChars: [Int: Int]

    init(reader: EbookFulltext, metadata: Data) throws {
        struct Structure: Decodable {
            struct Chapter: Decodable { let sourcePath: String; let textChars: Int? }
            let chapters: [Chapter]
        }
        let chapters = try JSONDecoder().decode(Structure.self, from: metadata).chapters
        var positions: [String: [Int]] = [:]
        for chapter in reader.chapters {
            guard let path = chapter.sourcePath else { continue }
            positions[EpubArchivePath.normalize(path), default: []].append(chapter.zeroBasedEpubIndex)
        }
        var mapping: [Int: Int] = [:]
        var used = Set<Int>()
        for (position, chapter) in chapters.enumerated() {
            guard let matches = positions[EpubArchivePath.normalize(chapter.sourcePath)],
                  matches.count == 1, let readerPosition = matches.first,
                  used.insert(readerPosition).inserted else {
                throw EmbeddedConverterError.conversionFailed(
                    "The reader and conversion structures have ambiguous or missing source chapters. Reopen the book before listening."
                )
            }
            mapping[position] = readerPosition
        }
        try Self.validate(mapping)
        coreToReader = mapping
        coreTextChars = Dictionary(uniqueKeysWithValues: chapters.enumerated().map { ($0.offset, $0.element.textChars ?? 0) })
    }

    private enum CodingKeys: String, CodingKey { case coreToReader, coreTextChars }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mapping = try values.decode([Int: Int].self, forKey: .coreToReader)
        try Self.validate(mapping)
        coreToReader = mapping
        coreTextChars = try values.decodeIfPresent([Int: Int].self, forKey: .coreTextChars) ?? [:]
    }

    private static func validate(_ mapping: [Int: Int]) throws {
        let keys = mapping.keys.sorted()
        let positions = keys.compactMap { mapping[$0] }
        guard !keys.isEmpty, keys == Array(0..<keys.count),
              positions.allSatisfy({ $0 >= 0 }), Set(positions).count == positions.count,
              positions == positions.sorted() else {
            // Playback uses ordered chapter windows. A reordered stale cache
            // needs rebuilding; guessing would play or omit unrelated text.
            throw EmbeddedConverterError.conversionFailed(
                "The reader and conversion chapter order differs. Reopen the book before listening."
            )
        }
    }

    func corePosition(for readerPosition: Int) throws -> Int {
        guard let position = coreToReader.first(where: { $0.value == readerPosition })?.key else {
            throw EmbeddedConverterError.conversionFailed("The selected reader chapter has no convertible source text.")
        }
        return position
    }

    func readerPosition(for corePosition: Int) throws -> Int {
        guard let position = coreToReader[corePosition] else {
            throw EmbeddedConverterError.conversionFailed("Conversion returned an unknown source chapter.")
        }
        return position
    }

    func event(_ data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EmbeddedConverterError.conversionFailed("Invalid conversion event.")
        }
        if let index = object["chapterIndex"] as? Int {
            object["chapterIndex"] = try readerPosition(for: index)
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    func manifest(_ data: Data) throws -> Data {
        guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var manifest = envelope["manifest"] as? [String: Any],
              var chapters = manifest["chapters"] as? [[String: Any]] else {
            throw EmbeddedConverterError.conversionFailed("Invalid conversion manifest.")
        }
        for position in chapters.indices {
            guard let index = chapters[position]["sourceIndex"] as? Int else {
                throw EmbeddedConverterError.conversionFailed("Conversion manifest omits source chapter identity.")
            }
            chapters[position]["sourceIndex"] = try readerPosition(for: index)
        }
        manifest["chapters"] = chapters
        envelope["manifest"] = manifest
        return try JSONSerialization.data(withJSONObject: envelope)
    }
}
