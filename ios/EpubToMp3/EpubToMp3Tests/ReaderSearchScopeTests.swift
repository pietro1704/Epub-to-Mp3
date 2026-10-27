import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderSearchScopeTests: XCTestCase {
    func testNativeSearchWalksLaterChaptersThenWrapsToEarlierChapters() async throws {
        let harness = try NativeReaderTestHarness(chapters: [
            NativeReaderTestHarness.chapter("Earlier unique passage.", index: 3),
            NativeReaderTestHarness.chapter("Currently displayed passage.", index: 7),
            NativeReaderTestHarness.chapter("Later unique passage.", index: 12)
        ])
        harness.installTeardown(in: self)
        harness.showChapter(1)
        harness.annotations.performSearch(query: "LATER UNIQUE")
        #if os(iOS)
        await harness.annotations.waitForSearchCompletion()
        #endif
        XCTAssertEqual(harness.document.selectedChapter, 2)
        XCTAssertTrue(harness.displayed.string.contains("Later unique"))
        XCTAssertEqual(UserDefaults.standard.integer(forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey), 11)
        harness.annotations.performSearch(query: "Earlier unique")
        #if os(iOS)
        await harness.annotations.waitForSearchCompletion()
        #endif
        XCTAssertEqual(harness.document.selectedChapter, 0)
        XCTAssertTrue(harness.displayed.string.contains("Earlier unique"))
        XCTAssertEqual(harness.persisted, 2)
        XCTAssertEqual(harness.renderedIndices, [1, 2, 0])
    }

    func testEmptyCatalogSearchCannotNavigateOrPersistProgress() async throws {
        let harness = try NativeReaderTestHarness(chapters: [])
        harness.installTeardown(in: self)
        harness.annotations.performSearch(query: "missing")
        #if os(iOS)
        await harness.annotations.waitForSearchCompletion()
        #endif
        XCTAssertTrue(harness.renderedIndices.isEmpty)
        XCTAssertEqual(harness.persisted, 0)
    }
}
