import XCTest
@testable import EpubToMp3

final class EmbeddedConversionCoordinatorTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testEmbeddedJobIDIsStablePerBook() {
        XCTAssertEqual(
            EmbeddedConversionCoordinator.jobID(for: "book-hash"),
            "embedded-book-hash"
        )
    }

    func testAudioPlayerResolvesEmbeddedFileURLs() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Services/AudioPlayer.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("hasPrefix(\"file://\")"))
        XCTAssertTrue(source.contains("URL(fileURLWithPath: path)"))
    }

    func testBookDetailUsesEmbeddedConversionWhenTheDeviceProviderIsSelected() throws {
        let iosSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Library/Views/BookDetailScreenController.swift"),
            encoding: .utf8
        )
        let macSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Library/Views/MacBookDetailViewController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(iosSource.contains("EmbeddedConversionCoordinator.stream"))
        XCTAssertTrue(macSource.contains("EmbeddedConversionCoordinator.stream"))
        XCTAssertTrue(macSource.contains("startRemoteConversion"))
        XCTAssertTrue(macSource.contains("recordConversion(jobId: response.jobId"))
        XCTAssertTrue(macSource.contains("alert.informativeText = error.localizedDescription"))
        XCTAssertTrue(macSource.contains("remoteStreamTask = Task {"))
    }

    func testEmbeddedConversionHasSegmentStreamingPath() throws {
        let coordinatorSource = try source("Features/Conversion/Services/EmbeddedConversionCoordinator.swift")
        let playerSource = try source("Features/Playback/Services/AudioPlayer.swift")
        XCTAssertTrue(coordinatorSource.contains("static func stream("))
        XCTAssertTrue(coordinatorSource.contains("convertChapterStreaming"))
        XCTAssertTrue(coordinatorSource.contains("player.enqueueSegment"))
        XCTAssertTrue(playerSource.contains("finishEmbeddedStreaming"))
        XCTAssertTrue(playerSource.contains("canonical chapter queue"))
    }
}
