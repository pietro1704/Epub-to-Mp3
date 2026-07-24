import XCTest

final class PlayerViewConfigurationTests: XCTestCase {
    func testSystemVolumeControlDoesNotUseDeprecatedRouteButtonAPI() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerScreenController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("MPVolumeView"))
        XCTAssertFalse(source.contains("showsRouteButton"))
    }

    func testLegacyPlayerViewWasRemovedAfterUIKitMigration() {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let legacyPlayerURL = projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/PlayerView.swift")
        let nativeURL = projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerScreenController.swift")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyPlayerURL.path),
            "The legacy SwiftUI PlayerView should stay removed once the UIKit player controllers own the iOS job-detail flow."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: nativeURL.path))
    }

    func testUIKitPlayerScreenReactsToPlaybackStateChanges() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/PlayerScreenController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("import Combine"))
        XCTAssertTrue(source.contains("private var cancellables: Set<AnyCancellable> = []"))
        XCTAssertTrue(source.contains("bindState()"))
        XCTAssertTrue(source.contains("player.objectWillChange"))
        XCTAssertTrue(source.contains("playbackClock.objectWillChange"))
        XCTAssertTrue(source.contains(".sink { [weak self] _ in self?.render() }"))
        XCTAssertTrue(source.contains("if let playerSnapshot = player.snapshot, playerSnapshot.jobId == snapshot.jobId"))
    }
}
