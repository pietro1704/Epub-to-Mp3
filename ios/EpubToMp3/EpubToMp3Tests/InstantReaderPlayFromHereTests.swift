import XCTest

final class InstantReaderPlayFromHereTests: XCTestCase {
    func testJumpToSentenceQueuesSentenceMenuInsteadOfSeekingImmediately() throws {
        let source = try instantReaderSource()

        XCTAssertTrue(
            source.contains("private func jumpToSentence(_ span: SentenceSpan) {\n        pendingPlayAnchor = span\n    }"),
            "InstantReaderView must store the tapped sentence so the long-press/tap flow can offer 'Play from here'."
        )
    }

    func testInstantReaderShowsPlayFromHereConfirmationDialog() throws {
        let source = try instantReaderSource()

        XCTAssertTrue(
            source.contains("confirmationDialog("),
            "InstantReaderView must present a confirmation dialog for sentence actions."
        )
        XCTAssertTrue(
            source.contains("reader.sentenceMenu.playFromHere"),
            "InstantReaderView must expose the localized 'Play from here' action."
        )
    }

    private func instantReaderSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/InstantReaderView.swift"),
            encoding: .utf8
        )
    }
}
