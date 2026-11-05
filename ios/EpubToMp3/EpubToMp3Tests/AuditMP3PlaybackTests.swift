import AVFoundation
import XCTest
@testable import EpubToMp3

@MainActor
final class AuditMP3PlaybackTests: XCTestCase {
    func testRetainedSegmentsExposeFullAppleDurationAndPausedSeekAfterRustRepair() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "mono-24000-48k-info", withExtension: "mp3"))
        let segment = try Data(contentsOf: fixture)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mp3-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("retained.mp3")
        let originalDuration = try AVAudioPlayer(contentsOf: fixture).duration
        try (0..<30).reduce(into: Data()) { data, _ in data.append(segment) }.write(to: path)
        let before = try AVAudioPlayer(contentsOf: path).duration
        XCTAssertLessThan(before, originalDuration * 2, "Reproduce Apple's segment-header duration failure")
        try ConverterFFIAdapter().prepareCompletedAudio(at: path)
        let duration = try AVAudioPlayer(contentsOf: path).duration
        XCTAssertEqual(duration, originalDuration * 30, accuracy: 0.1)
        let item = AVPlayerItem(url: path)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        defer { player.replaceCurrentItem(with: nil) }
        let assetDuration = try await item.asset.load(.duration).seconds
        XCTAssertEqual(assetDuration, duration, accuracy: 0.1)
        for seconds in [2.0, 17.0, 9.0, duration - 0.25] {
            let succeeded = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
            XCTAssertTrue(succeeded)
            XCTAssertEqual(player.currentTime().seconds, seconds, accuracy: 0.15)
            XCTAssertEqual(player.rate, 0, "Seeking a paused item must preserve pause")
        }
        try ConverterFFIAdapter().prepareCompletedAudio(at: path)
        XCTAssertEqual(try AVAudioPlayer(contentsOf: path).duration, duration, accuracy: 0.01)
    }
}
