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
        let controller = try instantReaderControllerSource()

        XCTAssertTrue(
            source.contains("@Published var pinnedReaderChapterIndex: Int?"),
            "A TOC selection needs a temporary reader pin in the shared reading state while audio is playing."
        )
        XCTAssertTrue(
            controller.contains("readingState.pinnedReaderChapterIndex = target"),
            "Selecting a TOC chapter on iOS must pin that selected EPUB index in the UIKit controller."
        )
        XCTAssertTrue(
            controller.contains("readingState.currentChapterIndex = target"),
            "Selecting a TOC chapter on iOS must also move the reader cursor in the UIKit controller."
        )
        XCTAssertTrue(
            controller.contains("player.play(snapshot: snapshot, startingAt: playableTarget)"),
            "Selecting a TOC chapter on iOS must resume playback from the mapped playable chapter in the UIKit controller."
        )
        XCTAssertTrue(
            source.contains("if let pinned = pinnedReaderChapterIndex"),
            "The audio position observer must not overwrite a user-selected TOC chapter while it is pinned."
        )
    }

    func testSelectionActionsPutReaderPlaybackBeforeTextActions() throws {
        let source = try interactionStateSource()
        let fromHere = source.range(of: "case playFromHere")?.lowerBound
        let continuePlayback = source.range(of: "case continuePlayback")?.lowerBound
        let sentence = source.range(of: "case sentence")?.lowerBound
        let paragraph = source.range(of: "case paragraph")?.lowerBound
        XCTAssertNotNil(fromHere)
        XCTAssertNotNil(continuePlayback)
        XCTAssertTrue(fromHere! < continuePlayback!)
        XCTAssertTrue(continuePlayback! < sentence!)
        XCTAssertTrue(sentence! < paragraph!)
        XCTAssertTrue(source.contains("static let menuOrder"))
    }

    func testReaderCanCloseAudioPlayerAndReopenWithLocalPlay() throws {
        let reader = try instantReaderSource()
        let controller = try instantReaderControllerSource()
        XCTAssertTrue(reader.contains("reader.closeAudioPlayer"))
        XCTAssertTrue(reader.contains("reader.reopenAudioPlayer"))
        XCTAssertTrue(reader.contains("if let onCloseAudioPlayer {"))
        XCTAssertTrue(reader.contains("if let onReopenAudioPlayer {"))
        XCTAssertTrue(controller.contains("private func handleCloseAudioPlayer()"))
        XCTAssertTrue(controller.contains("private func handleReopenAudioPlayer(currentChapterIndex: Int)"))
        XCTAssertTrue(controller.contains("player.stop()"))
        XCTAssertTrue(controller.contains("playerPresentation.dismissFullPlayer()"))
        XCTAssertTrue(controller.contains("onRequestPlay?(currentChapterIndex, nil)"))

        let fullPlayer = try fullPlayerSource()
        XCTAssertTrue(fullPlayer.contains("fullPlayer.close"))
    }

    private func fullPlayerSource() throws -> String {
        #if os(iOS)
        throw XCTSkip("Source-contract tests run on the host, not inside the iOS app sandbox")
        #else
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/FullPlayerSheet.swift"),
            encoding: .utf8
        )
        #endif
    }

    private func instantReaderControllerSource() throws -> String {
        #if os(iOS)
        throw XCTSkip("Source-contract tests run on the host, not inside the iOS app sandbox")
        #else
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/InstantReaderScreenController.swift"),
            encoding: .utf8
        )
        #endif
    }

    func testOpeningBookDoesNotStartAudioBootstrapAutomatically() throws {
        let source = try bookOpenSource()
        XCTAssertTrue(source.contains("ensureCacheManager()"))
        XCTAssertFalse(
            source.contains("startAudioBootstrap(startChapterIndex: max(0, savedChapter))"),
            "BookOpenView must wait for an explicit Play action before conversion"
        )
    }

    private func bookOpenSource() throws -> String {
        #if os(iOS)
        throw XCTSkip("Source-contract tests run on the host, not inside the iOS app sandbox")
        #else
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenView.swift"),
            encoding: .utf8
        )
        #endif
    }

    private func interactionStateSource() throws -> String {
        #if os(iOS)
        throw XCTSkip("Source-contract tests run on the host, not inside the iOS app sandbox")
        #else
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Services/ReaderInteractionState.swift"),
            encoding: .utf8
        )
        #endif
    }

    private func instantReaderSource() throws -> String {
        #if os(iOS)
        throw XCTSkip("Source-contract tests run on the host, not inside the iOS app sandbox")
        #else
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/InstantReaderView.swift"),
            encoding: .utf8
        )
        #endif
    }
}
