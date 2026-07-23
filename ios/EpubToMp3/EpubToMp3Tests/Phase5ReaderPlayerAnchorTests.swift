import XCTest
@testable import EpubToMp3

final class Phase5ReaderPlayerAnchorTests: XCTestCase {
    func testSegmentIDsCanResolveToReaderSpanIDsWhenBackendUsesDifferentIDs() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Chapter", text: "First sentence. Second sentence.",
            html: nil, css: nil, charCount: nil,
            segments: [
                .init(id: "backend-a", text: "First sentence.", startMs: 0, endMs: 1_000),
                .init(id: "backend-b", text: "Second sentence.", startMs: 1_000, endMs: 2_000),
            ]
        )
        let engine = SyncEngine()
        engine.load(chapter: chapter, chapterDurationSeconds: 2)

        XCTAssertEqual(engine.update(positionSeconds: 0.5), "backend-a")
        XCTAssertEqual(engine.readerSentenceID(forTimingID: "backend-a"), engine.spans[0].id)
        XCTAssertEqual(engine.readerSentenceID(forTimingID: "backend-b"), engine.spans[1].id)
    }

    func testPlayerReaderDirectChapterNavigationPublishesCoordinatorChapter() throws {
        let source = try source(named: "Features/Reader/Views/PlayerReaderView.swift")
        XCTAssertTrue(source.contains("readerCoordinator.setChapter(targetEpubIndex)"))
        XCTAssertTrue(source.contains("readerCoordinator.setChapter(targetEpubIndex)"))
        XCTAssertTrue(source.contains("readerCoordinator.setChapter(epubIndex)"))
    }

    func testInstantReaderScrollPublishesRatioAndSentenceAnchor() throws {
        let reader = try source(named: "Features/Reader/Views/ReaderView.swift")
        let attributed = try source(named: "Features/Reader/Views/AttributedPageView.swift")
        XCTAssertTrue(reader.contains("onScrollPosition: { ratio, sentenceId in"))
        XCTAssertTrue(reader.contains("readerCoordinator.setPagePosition(ratio: ratio, sentenceId: sentenceId)"))
        XCTAssertTrue(attributed.contains("onScrollPosition"))
        XCTAssertTrue(attributed.contains("scrollViewDidScroll"))
    }

    private func source(named path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: projectRoot.appendingPathComponent("EpubToMp3/\(path)"), encoding: .utf8)
    }
}
