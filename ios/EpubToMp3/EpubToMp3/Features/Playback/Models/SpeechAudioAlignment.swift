import Foundation

/// Measured word boundaries embedded by Rust in the exact MP3 being played.
/// Missing/invalid metadata never becomes a proportional word estimate.
struct SpeechAudioAlignment: Equatable, Sendable {
    struct Word: Codable, Equatable, Sendable {
        let location: Int
        let length: Int
        let start: Double
        let end: Double
        var range: NSRange { NSRange(location: location, length: length) }
    }
    struct Passage: Codable, Equatable, Sendable {
        let version: Int
        let text: String
        let words: [Word]
        let audioStart: Double
        let sourceOffset: Int?

        func word(at seconds: Double) -> Word? {
            words.last { seconds >= audioStart + $0.start && seconds < audioStart + $0.end }
        }
    }
    let passages: [Passage]
    private static let owner = Data("epubtomp3.speech-alignment\0".utf8)
    private static let maximumTagBytes = 4 * 1024 * 1024 + 1024

    init?(tag: Data) {
        let bytes = [UInt8](tag)
        guard bytes.count >= 10, bytes.count <= Self.maximumTagBytes,
              Array(bytes[0..<3]) == [73, 68, 51], [3, 4].contains(bytes[3]), bytes[5] == 0,
              bytes[6..<10].allSatisfy({ $0 < 128 }) else { return nil }
        let end = 10 + bytes[6..<10].reduce(0) { $0 * 128 + Int($1) }
        guard end <= bytes.count else { return nil }
        var cursor = 10
        var decoded: [Passage]?
        while cursor + 10 <= end {
            let length = bytes[(cursor + 4)..<(cursor + 8)]
            guard bytes[3] != 4 || length.allSatisfy({ $0 < 128 }) else { return nil }
            let count = length.reduce(0) { $0 * (bytes[3] == 4 ? 128 : 256) + Int($1) }
            guard count <= end - cursor - 10 else { return nil }
            let payload = Data(bytes[(cursor + 10)..<(cursor + 10 + count)])
            if Array(bytes[cursor..<(cursor + 4)]) == [80, 82, 73, 86], payload.starts(with: Self.owner) {
                guard bytes[cursor + 8] == 0, bytes[cursor + 9] == 0 else { return nil }
                decoded = try? JSONDecoder().decode([Passage].self, from: payload.dropFirst(Self.owner.count))
            }
            cursor += 10 + count
            if count == 0 { break }
        }
        guard let decoded, !decoded.isEmpty, decoded.count <= 20_000,
              decoded.allSatisfy(Self.valid),
              zip(decoded, decoded.dropFirst()).allSatisfy({ $0.audioStart <= $1.audioStart }) else { return nil }
        passages = decoded
    }

    static func read(from url: URL) -> Self? {
        guard url.isFileURL, let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 10), header.count == 10,
              header.prefix(3) == Data("ID3".utf8), header[6..<10].allSatisfy({ $0 < 128 }) else { return nil }
        let count = header[6..<10].reduce(0) { $0 * 128 + Int($1) }
        guard count <= maximumTagBytes - 10,
              let body = try? file.read(upToCount: count), body.count == count else { return nil }
        return Self(tag: header + body)
    }

    func spokenWord(at seconds: Double) -> (passage: Passage, word: Word)? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        for passage in passages.reversed() where passage.audioStart <= seconds {
            if let word = passage.word(at: seconds) { return (passage, word) }
        }
        return nil
    }

    private static func valid(_ passage: Passage) -> Bool {
        guard passage.version == 1, passage.audioStart.isFinite, passage.audioStart >= 0,
              passage.sourceOffset.map({ $0 >= 0 }) ?? true,
              !passage.words.isEmpty, passage.words.count <= 20_000 else { return false }
        let text = passage.text as NSString
        func scalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0, offset < text.length else { return true }
            return !(0xD800...0xDBFF).contains(text.character(at: offset - 1))
                || !(0xDC00...0xDFFF).contains(text.character(at: offset))
        }
        for word in passage.words {
            guard word.location >= 0, word.length > 0, word.location <= text.length,
                  word.length <= text.length - word.location,
                  word.start.isFinite, word.end.isFinite,
                  word.start >= 0, word.end > word.start,
                  scalarBoundary(word.location), scalarBoundary(NSMaxRange(word.range)) else { return false }
        }
        return zip(passage.words, passage.words.dropFirst()).allSatisfy {
            $0.end <= $1.start + 0.001 && NSMaxRange($0.range) <= $1.location
        }
    }
}
