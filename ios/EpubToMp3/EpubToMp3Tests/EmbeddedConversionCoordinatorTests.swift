import XCTest
@testable import EpubToMp3

final class EmbeddedConversionCoordinatorTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3")
                .appendingPathComponent(relativePath)
        )
    }

    func testEmbeddedJobIDIsStablePerBook() {
        XCTAssertEqual(
            EmbeddedConversionCoordinator.jobID(for: "book-hash"),
            "embedded-book-hash"
        )
    }

    func testAudioPlayerResolvesEmbeddedFileURLs() throws {
        let source = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Playback/Services/AudioPlayer.swift")
        )
        XCTAssertTrue(source.contains("hasPrefix(\"file://\")"))
        XCTAssertTrue(source.contains("URL(fileURLWithPath: path)"))
    }

    func testBookDetailUsesEmbeddedConversionWhenTheDeviceProviderIsSelected() throws {
        let iosSource = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Library/Views/BookDetailScreenController.swift")
        )
        let macSource = try readSourceFileIfAvailable(
            at: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Features/Library/Views/MacBookDetailViewController.swift")
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
