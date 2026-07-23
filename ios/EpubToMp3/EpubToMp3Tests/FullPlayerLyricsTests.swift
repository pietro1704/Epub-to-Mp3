import XCTest
@testable import EpubToMp3

final class FullPlayerLyricsTests: XCTestCase {

    func testLyricsSentencePrefersSegmentModeActiveSentenceId() {
        let spans = [
            SentenceSpan(id: "1:0", text: "First sentence.", startChar: 0, endChar: 15),
            SentenceSpan(id: "1:1", text: "Second sentence.", startChar: 16, endChar: 32)
        ]

        XCTAssertEqual(
            FullPlayerLyricsState.currentSentenceText(
                spans: spans,
                syncSentenceId: "1:0",
                activeSentenceId: "1:1"
            ),
            "Second sentence."
        )
    }

    func testLyricsSentenceFallsBackToSyncSentenceId() {
        let spans = [
            SentenceSpan(id: "1:0", text: "First sentence.", startChar: 0, endChar: 15),
            SentenceSpan(id: "1:1", text: "Second sentence.", startChar: 16, endChar: 32)
        ]

        XCTAssertEqual(
            FullPlayerLyricsState.currentSentenceText(
                spans: spans,
                syncSentenceId: "1:0",
                activeSentenceId: nil
            ),
            "First sentence."
        )
    }

    func testTutorialSeenKeyIsStable() {
        XCTAssertEqual(
            FullPlayerLyricsState.tutorialSeenKey,
            "fullPlayer.coverLyricsTutorialSeen"
        )
    }

    func testFullPlayerSourceWiresCoverTapTutorialAndLyricsOverlay() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("EpubToMp3/Views/FullPlayerSheet.swift")
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw XCTSkip("Source-file contract test runs only when the repository tree is available.")
        }
        let source = try String(contentsOf: sourceURL)

        XCTAssertTrue(source.contains("Button {"),
                      "Cover art must be tappable to toggle sentence lyrics.")
        XCTAssertTrue(source.contains("showLyricsOverlay"),
                      "Full player must carry lyrics overlay state.")
        XCTAssertTrue(source.contains("fullPlayer.coverLyricsTutorialSeen"),
                      "Cover-tap tutorial must be shown once and persisted.")
    }
}
