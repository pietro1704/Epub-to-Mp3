import Foundation
import zlib

/// Creates a shareable ZIP from the audio currently available on device.
/// The archive is intentionally STORE-only: MP3 data is already compressed,
/// avoiding wasted CPU and preserving fast export on compact iPhones.
enum LocalAudiobookArchiveExporter {
    enum Availability: String, Equatable, Sendable {
        case pending
        case generating
        case waitingForWiFi
        case available
        case failed
        case missing
    }

    struct Chapter: Sendable {
        let index: Int
        let title: String
        let fileURL: URL
        let availability: Availability
        let lastError: String?

        init(
            index: Int,
            title: String,
            fileURL: URL,
            availability: Availability = .available,
            lastError: String? = nil
        ) {
            self.index = index
            self.title = title
            self.fileURL = fileURL
            self.availability = availability
            self.lastError = lastError
        }
    }

    private struct Manifest: Codable {
        struct ChapterEntry: Codable {
            let index: Int
            let title: String
            let fileName: String
            let bytes: Int64
        }

        struct MissingChapterEntry: Codable {
            let index: Int
            let title: String
            let state: String
            let error: String?
        }

        let formatVersion: Int
        let bookID: String
        let bookTitle: String
        let author: String?
        let isPartial: Bool
        let chapters: [ChapterEntry]
        let missingChapters: [MissingChapterEntry]
    }

    private struct Entry {
        let name: String
        let data: Data
    }

    enum ExportError: LocalizedError {
        case noAudio
        case fileTooLarge(URL)

        var errorDescription: String? {
            switch self {
            case .noAudio:
                return "No completed audio is available to export."
            case .fileTooLarge(let url):
                return "The export file is too large for a standard ZIP: \(url.lastPathComponent)."
            }
        }
    }

    static func export(
        bookID: String,
        bookTitle: String,
        author: String?,
        chapters: [Chapter],
        destinationDirectory: URL
    ) throws -> URL {
        let completed = chapters
            .sorted { $0.index < $1.index }
            .compactMap { chapter -> (Chapter, Data)? in
                guard chapter.availability == .available,
                      let data = try? Data(contentsOf: chapter.fileURL, options: .mappedIfSafe),
                      !data.isEmpty else {
                    return nil
                }
                return (chapter, data)
            }
        guard !completed.isEmpty else { throw ExportError.noAudio }

        let chapterEntries = completed.map { chapter, data -> Entry in
            let fileName = String(format: "%03d - %@.mp3", chapter.index + 1, safeFileName(chapter.title))
            return Entry(name: fileName, data: data)
        }
        let completedIndices = Set(completed.map { $0.0.index })
        let missingChapters = chapters
            .sorted { $0.index < $1.index }
            .compactMap { chapter -> Manifest.MissingChapterEntry? in
                guard !completedIndices.contains(chapter.index) else { return nil }
                let state: Availability = chapter.availability == .available ? .missing : chapter.availability
                return Manifest.MissingChapterEntry(
                    index: chapter.index,
                    title: chapter.title,
                    state: state.rawValue,
                    error: chapter.lastError
                )
            }
        let manifest = Manifest(
            formatVersion: 1,
            bookID: bookID,
            bookTitle: bookTitle,
            author: author,
            isPartial: !missingChapters.isEmpty,
            chapters: zip(chapterEntries, completed).map { entry, source in
                Manifest.ChapterEntry(
                    index: source.0.index,
                    title: source.0.title,
                    fileName: entry.name,
                    bytes: Int64(source.1.count)
                )
            },
            missingChapters: missingChapters
        )
        let manifestData = try JSONEncoder.prettySorted.encode(manifest)
        var archiveEntries = chapterEntries
        archiveEntries.append(Entry(name: "manifest.json", data: manifestData))

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let archiveURL = destinationDirectory
            .appendingPathComponent(safeFileName(bookTitle) + ".zip")
        try writeStoredZip(entries: archiveEntries, to: archiveURL)
        return archiveURL
    }

    private static func writeStoredZip(entries: [Entry], to url: URL) throws {
        var archive = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for entry in entries {
            guard entry.data.count <= Int(UInt32.max), entry.name.utf8.count <= Int(UInt16.max) else {
                throw ExportError.fileTooLarge(url)
            }
            let nameData = Data(entry.name.utf8)
            let crc = entry.data.withUnsafeBytes { rawBuffer -> UInt32 in
                UInt32(truncatingIfNeeded: crc32(
                    0,
                    rawBuffer.bindMemory(to: Bytef.self).baseAddress,
                    uInt(entry.data.count)
                ))
            }
            let size = UInt32(entry.data.count)

            archive.appendUInt32LE(0x04034B50)
            archive.appendUInt16LE(20)
            archive.appendUInt16LE(0x0800)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt16LE(0)
            archive.appendUInt32LE(crc)
            archive.appendUInt32LE(size)
            archive.appendUInt32LE(size)
            archive.appendUInt16LE(UInt16(nameData.count))
            archive.appendUInt16LE(0)
            archive.append(nameData)
            archive.append(entry.data)

            centralDirectory.appendUInt32LE(0x02014B50)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(20)
            centralDirectory.appendUInt16LE(0x0800)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(crc)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt32LE(size)
            centralDirectory.appendUInt16LE(UInt16(nameData.count))
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt16LE(0)
            centralDirectory.appendUInt32LE(0)
            centralDirectory.appendUInt32LE(offset)
            centralDirectory.append(nameData)

            guard archive.count <= Int(UInt32.max) else { throw ExportError.fileTooLarge(url) }
            offset = UInt32(archive.count)
        }

        guard entries.count <= Int(UInt16.max), centralDirectory.count <= Int(UInt32.max) else {
            throw ExportError.fileTooLarge(url)
        }
        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)
        archive.appendUInt32LE(0x06054B50)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(0)
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt16LE(UInt16(entries.count))
        archive.appendUInt32LE(UInt32(centralDirectory.count))
        archive.appendUInt32LE(centralOffset)
        archive.appendUInt16LE(0)
        try archive.write(to: url, options: .atomic)
    }

    private static func safeFileName(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = value
            .components(separatedBy: forbidden)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "Audiobook" : cleaned).prefix(120))
    }
}

private extension JSONEncoder {
    static var prettySorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0x00FF))
        append(UInt8((value & 0xFF00) >> 8))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0x000000FF))
        append(UInt8((value & 0x0000FF00) >> 8))
        append(UInt8((value & 0x00FF0000) >> 16))
        append(UInt8((value & 0xFF000000) >> 24))
    }
}
