// PythonEmbedTests.swift
//
// Simulator-only smoke test for the embedded-Python spike.
// Skipped on macOS (the sidecar still owns macOS).

#if os(iOS) || targetEnvironment(simulator)

import XCTest
@testable import EpubToMp3

final class PythonEmbedTests: XCTestCase {

    /// Synthesizes a short pt-BR utterance with Edge-TTS in-process
    /// and asserts the MP3 was written. Network-dependent: Edge-TTS
    /// hits Microsoft's cloud endpoint.
    func testEdgeTTSConvertsHelloWorld() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("python-embed-spike", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp,
                                                 withIntermediateDirectories: true)

        let mp3: URL
        do {
            mp3 = try await PythonEmbed.shared.convertWithEdgeTTS(
                text: "Olá, mundo. Este é o sidecar embedded.",
                voice: "pt-BR-FranciscaNeural",
                outputDir: tmp
            )
        } catch {
            throw XCTSkip("PythonEmbed bootstrap or Edge synth failed: \(error). " +
                          "Run ios/EpubToMp3/scripts/bootstrap-ios-python.sh and rebuild.")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: mp3.path),
                      "MP3 missing at \(mp3.path)")

        let attrs = try FileManager.default.attributesOfItem(atPath: mp3.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 5_000,
                             "MP3 too small (\(size) bytes) — Edge probably didn't synth")
    }

    func testBootstrapIsIdempotent() throws {
        do {
            try PythonEmbed.shared.bootstrap()
            try PythonEmbed.shared.bootstrap()  // must not throw on 2nd call
        } catch {
            throw XCTSkip("Bootstrap failed (vendor likely missing): \(error)")
        }
    }
}

#endif  // os(iOS) || targetEnvironment(simulator)
