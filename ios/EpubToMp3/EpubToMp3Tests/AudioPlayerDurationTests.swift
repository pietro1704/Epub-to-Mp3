import XCTest
@testable import EpubToMp3

final class AudioPlayerDurationTests: XCTestCase {
    func testValidatedDurationAcceptsOnlyPositiveFiniteReadyValues() {
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(Double.nan, isReadyToPlay: false))
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(0, isReadyToPlay: false))
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(Double.nan, isReadyToPlay: true))
        XCTAssertNil(AudioPlayer.validatedDurationSeconds(0, isReadyToPlay: true))
        XCTAssertEqual(AudioPlayer.validatedDurationSeconds(3600, isReadyToPlay: true), 3600)
        XCTAssertEqual(AudioPlayer.validatedDurationSeconds(12.5, isReadyToPlay: true), 12.5)
    }

    func testAudioPlayerObservesItemStatusAndDurationForEarlyScrubberDuration() throws {
        let source = try sourceFile(named: "AudioPlayer.swift")

        XCTAssertTrue(
            source.contains("publisher(for: \\.status)"),
            "AudioPlayer must observe AVPlayerItem.status so durationSeconds updates as soon as the item becomes ready instead of waiting for the 250ms timer."
        )
        XCTAssertTrue(
            source.contains("publisher(for: \\.duration)"),
            "AudioPlayer must observe AVPlayerItem.duration so later duration changes refresh the scrubber immediately."
        )
    }

    private func sourceFile(named name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Services/\(name)"),
            encoding: .utf8
        )
    }
}
