import XCTest
@testable import EpubToMp3

/// Opt-in simulator smoke for the in-process iOS audio engine.
///
/// This hits the same Swift Edge-TTS bridge used by the embedded runtime
/// path without requiring a full UI-driven book import. It is skipped by
/// default so normal CI is not coupled to external network availability.
final class EmbeddedEngineRuntimeTests: XCTestCase {
    func testEdgeTTSWritesPlayableMp3OnSimulator() async throws {
        #if os(iOS)
        #if LIVE_ENGINE_SMOKE
        #else
        throw XCTSkip("Build with OTHER_SWIFT_FLAGS='$(inherited) -D LIVE_ENGINE_SMOKE' to run the live embedded-engine smoke test.")
        #endif

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("embedded-engine-smoke", isDirectory: true)
        try? FileManager.default.removeItem(at: outputDir)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let url = try await PythonEmbed.shared.convertWithEdgeTTS(
            text: "This is a short simulator smoke test for the internal conversion engine.",
            voice: "en-US-AriaNeural",
            outputDir: outputDir
        )

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1_000, "Edge-TTS should write a non-empty MP3 file.")
        XCTAssertTrue(
            data.starts(with: Data([0x49, 0x44, 0x33])) || data.starts(with: Data([0xFF])),
            "Output should look like MP3 bytes, path: \(url.path)"
        )
        #else
        throw XCTSkip("Embedded Edge-TTS runtime smoke is only available on iOS.")
        #endif
    }
}
