import Foundation

/// Silent MPEG-1 Layer III audio made of whole frames.
///
/// Completed chapter files pass through `converter_audio_prepare_v1` before
/// playback (#1108), and Rust rejects a file that ends inside a frame. A lone
/// header followed by arbitrary padding is therefore not a completed chapter;
/// each frame here is exactly 417 bytes (128 kbps, 44.1 kHz, no padding) with
/// zeroed side information, which decodes as silence.
enum CompletedMP3Fixture {
    static let frameBytes = 417

    static func data(frames: Int = 4) -> Data {
        var frame = Data([0xFF, 0xFB, 0x90, 0x00])
        frame.append(contentsOf: [UInt8](repeating: 0, count: frameBytes - 4))
        return Data((0..<max(1, frames)).flatMap { _ in frame })
    }

    /// Writes the fixture to a unique temporary file and returns its URL.
    static func write(named name: String = "chapter", frames: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).mp3")
        try data(frames: frames).write(to: url)
        return url
    }
}
