import XCTest

final class BookOpenViewPriorityTests: XCTestCase {
    func testBookOpenViewThreadsStartChapterIndexIntoRemoteBootstrapHelpers() throws {
        let source = try sourceFile(named: "BookOpenView.swift")

        XCTAssertTrue(
            source.contains("await self.waitForBackendThenBootstrap(startChapterIndex: startChapterIndex)"),
            "Remote bootstrap must thread the requested EPUB zero-based chapter into waitForBackendThenBootstrap instead of dropping it."
        )
        XCTAssertTrue(
            source.contains("private func waitForBackendThenBootstrap(startChapterIndex: Int) async"),
            "waitForBackendThenBootstrap must accept the requested EPUB zero-based chapter index."
        )
        XCTAssertTrue(
            source.contains("await bootstrapAudio(client: client, startChapterIndex: startChapterIndex)"),
            "Once the backend client becomes available, the requested chapter must continue into bootstrapAudio."
        )
        XCTAssertTrue(
            source.contains("private func bootstrapAudio(client: APIClient, startChapterIndex: Int) async"),
            "bootstrapAudio must accept the requested EPUB zero-based chapter index."
        )
    }

    func testBookOpenViewSubmitsPriorityChapterIndexToConvertOptions() throws {
        let source = try sourceFile(named: "BookOpenView.swift")

        XCTAssertTrue(
            source.contains("opts.priorityChapterIndex = startChapterIndex"),
            "Remote conversion submission must persist the requested EPUB zero-based chapter as the backend priority hint."
        )
    }

    func testApiClientConvertOptionsExposesPriorityChapterIndex() throws {
        let source = try apiClientSource()

        XCTAssertTrue(
            source.contains("var priorityChapterIndex: Int? = nil"),
            "ConvertOptions must expose an optional priorityChapterIndex field for remote on-demand streaming prioritization."
        )
        XCTAssertTrue(
            source.contains("appendField(name: \"priority_chapter_index\", value: String(priorityChapterIndex))"),
            "submitConversion must serialize priority_chapter_index when the caller provides it."
        )
    }

    func testInstantReaderForwardsSubsequentSnapshotsIntoMountedPlayer() throws {
        let source = try sourceFile(named: "InstantReaderView.swift")

        XCTAssertTrue(
            source.contains(".compatOnChange(of: snapshot) { updatedSnapshot in"),
            "InstantReaderView must observe snapshot changes after the first playable chapter appears."
        )
        XCTAssertTrue(
            source.contains("player.updateSnapshot(updatedSnapshot)"),
            "Mounted remote audio must receive every later SSE snapshot so newly completed chapters append to the live queue."
        )
    }

    func testPlayButtonsCompareReaderPageRatioBeforeResuming() throws {
        let sources = [
            try sourceFile(named: "MiniPlayerBar.swift"),
            try sourceFile(named: "FullPlayerSheet.swift"),
            try sourceFile(named: "PlayerReaderView.swift"),
            try sourceFile(named: "InstantReaderView.swift"),
            try sourceFile(named: "PlayerView.swift"),
        ]

        for source in sources {
            XCTAssertTrue(
                source.contains("readerPageRatio:"),
                "Every play surface must pass the reader page ratio into AudioPlayer so same-chapter divergence still shows the chooser."
            )
        }
    }

    func testPlayerReaderViewPassesOnLinkTapToReaderView() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/PlayerReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("onLinkTap:"),
            "PlayerReaderView must wire onLinkTap into ReaderView so link taps don't fall through to page-turn gesture."
        )
        XCTAssertTrue(
            source.contains("handleEpubLink"),
            "PlayerReaderView must implement handleEpubLink to navigate EPUB-internal hrefs."
        )
    }

    func testReaderViewLinkHitOriginUsesColumnCentredX() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/ReaderView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("containerSize.width - columnW") || source.contains("(containerSize.width - columnW) / 2"),
            "textOriginX must derive from the centred column position, not just margin, so link hit-rects match visual layout."
        )
    }

    func testReaderViewGuardsTextOffsetAgainstEmptyPagesAndZeroOffset() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("EpubToMp3/Views/ReaderView.swift"),
            encoding: .utf8
        )
        // Rapid slide page turns can cause livePages() to transiently return []
        // while UIPageViewController re-renders. Writing 0 from an empty array
        // (or a non-zero page whose cumulativeOffset lands at 0 mid-animation)
        // lets syncPageToTextOffset reset currentPage to 0. The guard ensures
        // textOffsetAtCurrentPage is only updated when the page list is non-empty
        // and the offset is coherent.
        XCTAssertTrue(
            source.contains("guard !currentPages.isEmpty else { return }"),
            "compatOnChange(of: currentPage) must guard against empty livePages() to prevent textOffsetAtCurrentPage being zeroed during rapid turns."
        )
        XCTAssertTrue(
            source.contains("if offset > 0 || newPage == 0"),
            "compatOnChange(of: currentPage) must skip writing offset 0 for pages > 0 to prevent mid-animation zero from resetting the reading position."
        )
    }

    func testFullPlayerSheetTocButtonUsesTocDrawer() throws {
        let source = try sourceFile(named: "FullPlayerSheet.swift")
        XCTAssertTrue(
            source.contains("TocDrawer("),
            "FullPlayerSheet TOC button must open TocDrawer, not ChapterListSheet."
        )
        XCTAssertFalse(
            source.contains("ChapterListSheet(player:"),
            "ChapterListSheet must not be used from FullPlayerSheet — TocDrawer is the canonical TOC UI."
        )
    }

    private func sourceFile(named name: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Views/\(name)"),
            encoding: .utf8
        )
    }

    private func apiClientSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent("EpubToMp3/Services/APIClient.swift"),
            encoding: .utf8
        )
    }
}
