import XCTest

final class PlayerViewConfigurationTests: XCTestCase {
    func testSystemVolumeControlDoesNotUseDeprecatedRouteButtonAPI() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Features/Playback/Views/PlayerView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("MPVolumeView"))
        XCTAssertTrue(source.contains("showsVolumeSlider = true"))
        XCTAssertFalse(source.contains("showsRouteButton"))
    }
}
