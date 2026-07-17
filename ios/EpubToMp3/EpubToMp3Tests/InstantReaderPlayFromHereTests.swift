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

    func testSelectionActionsPutReaderPlaybackBeforeTextActions() throws {
        let source = try interactionStateSource()
        let fromHere = source.range(of: "case playFromHere")?.lowerBound
        let chapterStart = source.range(of: "case playChapterStart")?.lowerBound
        let sentence = source.range(of: "case sentence")?.lowerBound
        let paragraph = source.range(of: "case paragraph")?.lowerBound
        XCTAssertNotNil(fromHere)
        XCTAssertNotNil(chapterStart)
        XCTAssertTrue(fromHere! < chapterStart!)
        XCTAssertTrue(chapterStart! < sentence!)
        XCTAssertTrue(sentence! < paragraph!)
        XCTAssertTrue(source.contains("static let menuOrder"))
    }

    func testReaderCanCloseAudioPlayerAndReopenWithLocalPlay() throws {
        let reader = try instantReaderSource()
        XCTAssertTrue(reader.contains("reader.closeAudioPlayer"))
        XCTAssertTrue(reader.contains("reader.reopenAudioPlayer"))
        XCTAssertTrue(reader.contains("private func closeAudioPlayer()"))
        XCTAssertTrue(reader.contains("private func reopenAudioPlayer()"))

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
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/FullPlayerSheet.swift"),
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
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/BookOpenView.swift"),
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
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Services/ReaderInteractionState.swift"),
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
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/InstantReaderView.swift"),
            encoding: .utf8
        )
        #endif
    }
}
