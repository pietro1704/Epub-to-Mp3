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

    func testTocSelectionIsNotImmediatelyOverriddenByAudioFollow() throws {
        let source = try instantReaderSource()

        XCTAssertTrue(
            source.contains("@State private var pinnedReaderChapterIndex: Int?"),
            "A TOC selection needs a temporary reader pin while audio is playing."
        )
        XCTAssertTrue(
            source.contains("pinnedReaderChapterIndex = target"),
            "Selecting a TOC chapter must pin that selected EPUB index before dismissing the sheet."
        )
        XCTAssertTrue(
            source.contains("if let pinned = pinnedReaderChapterIndex"),
            "The audio position observer must not overwrite a user-selected TOC chapter while it is pinned."
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
