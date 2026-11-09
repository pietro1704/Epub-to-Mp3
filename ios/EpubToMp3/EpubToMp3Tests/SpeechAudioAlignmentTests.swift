import XCTest
import AVFoundation
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class SpeechAudioAlignmentTests: XCTestCase {
    static func tag(_ json: String, version: UInt8 = 3) -> Data {
        let payload = Data("epubtomp3.speech-alignment\0".utf8) + Data(json.utf8)
        var frame = Data("PRIV".utf8)
        let count = UInt32(payload.count)
        var length = (version == 4 ? ((count >> 21) << 24) | (((count >> 14) & 127) << 16)
            | (((count >> 7) & 127) << 8) | (count & 127) : count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(contentsOf: [0, 0]); frame.append(payload)
        let n = frame.count
        return Data([73, 68, 51, version, 0, 0, UInt8((n >> 21) & 127), UInt8((n >> 14) & 127),
                     UInt8((n >> 7) & 127), UInt8(n & 127)]) + frame
    }

    func testMeasuredTimingDistinguishesRepeatedWordsAndUsesMediaTimeAtAnyRate() throws {
        let metadata = Self.tag(#"[{"version":1,"text":"👋 hello hello","audioStart":8,"sourceOffset":42,"words":[{"location":3,"length":5,"start":0.1,"end":0.3},{"location":9,"length":5,"start":1.7,"end":2.1}]}]"#)
        let alignment = try XCTUnwrap(SpeechAudioAlignment(tag: metadata))
        XCTAssertEqual(alignment.spokenWord(at: 8.2)?.word.location, 3)
        XCTAssertNil(alignment.spokenWord(at: 9), "Silence must not invent an active word")
        XCTAssertEqual(alignment.spokenWord(at: 9.8)?.word.location, 9)
        XCTAssertEqual(alignment.spokenWord(at: 9.8)?.passage.sourceOffset, 42)
        XCTAssertNil(alignment.spokenWord(at: .nan))
        XCTAssertNil(SpeechAudioAlignment(tag: metadata.dropLast()))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try (metadata + Data(repeating: 255, count: 1024)).write(to: file)
        XCTAssertEqual(SpeechAudioAlignment.read(from: file), alignment)
        let headerLength = 10 + 10 + Data("epubtomp3.speech-alignment\0".utf8).count
        let json = String(decoding: metadata.dropFirst(headerLength), as: UTF8.self)
        XCTAssertEqual(SpeechAudioAlignment(tag: Self.tag(json, version: 4)), alignment,
                       "Cover publication may rewrite the MP3 tag to ID3v2.4")
    }

    func testInvalidRangesTimesAndVersionsFailClosed() {
        for word in [#"{"location":999,"length":1,"start":0,"end":1}"#,
                     #"{"location":0,"length":1,"start":2,"end":1}"#,
                     #"{"location":1,"length":1,"start":0,"end":1}"#] {
            XCTAssertNil(SpeechAudioAlignment(tag: Self.tag("[{\"version\":1,\"text\":\"👋\",\"audioStart\":0,\"words\":[\(word)]}]")))
        }
        XCTAssertNil(SpeechAudioAlignment(tag: Data()))
    }

    func testRenderedWordResolvesWhitespaceAndRepeatedPassagesBySourceIdentity() throws {
        let metadata = Self.tag(#"[{"version":1,"text":"hello hello.","audioStart":0,"sourceOffset":13,"words":[{"location":6,"length":5,"start":0.2,"end":1.2}]}]"#)
        let passage = try XCTUnwrap(SpeechAudioAlignment(tag: metadata)?.passages.first)
        let rendered = "hello\nhello.\n\nhello   hello."
        let range = try XCTUnwrap(ReaderSpokenTextResolver.word(passage.words[0], passage: passage,
            chapterText: "hello hello. hello hello.", renderedText: rendered))
        XCTAssertEqual(range.location, 22)
        XCTAssertEqual((rendered as NSString).substring(with: range), "hello")
        XCTAssertNil(ReaderSpokenTextResolver.word(passage.words[0], passage: passage,
            chapterText: "unrelated chapter", renderedText: rendered))
    }

    @MainActor
    func testReplacingTheCurrentItemRejectsPendingAndMissingAlignment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func file(_ name: String) throws -> URL {
            let path = root.appendingPathComponent(name + ".mp3")
            try Self.tag("[{\"version\":1,\"text\":\"\(name)\",\"audioStart\":0,\"words\":[{\"location\":0,\"length\":1,\"start\":0,\"end\":1}]}]").write(to: path)
            return path
        }
        let first = AVPlayerItem(url: try file("first"))
        let replacement = AVPlayerItem(url: try file("replacement"))
        let missing = AVPlayerItem(url: root.appendingPathComponent("missing.mp3"))
        let cache = PlaybackSpeechAlignment()
        XCTAssertNil(cache.current(first))
        XCTAssertNil(cache.current(replacement))
        let deadline = Date().addingTimeInterval(2)
        while cache.current(replacement) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(cache.current(replacement)?.passages.first?.text, "replacement")
        XCTAssertNil(cache.current(missing), "A new item cannot inherit the previous item's timing")
        XCTAssertNil(cache.current(nil))
    }
}
