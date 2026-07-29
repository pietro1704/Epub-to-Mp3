import XCTest

/// Source-contract tests for the slice-2 reading progress + viewport-snap
/// pagination wiring: both native reader controllers must persist/restore
/// via `ReaderProgressStore` and snap scroll position in `.paginated` mode.
/// See `docs/reader-spec-comparison.md` P0 gap #2.
final class ReaderPaginationWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readSourceFileIfAvailable(
            at: root.appendingPathComponent("EpubToMp3/\(relativePath)")
        )
    }

    func testBookOpenScreenControllerSnapsAndPersistsProgress() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")

        XCTAssertTrue(source.contains("UIScrollViewDelegate"))
        XCTAssertTrue(source.contains("scrollViewWillEndDragging"))
        XCTAssertTrue(source.contains("settings.readerLayout == .paginated"))
        XCTAssertTrue(source.contains("ReaderProgressStore.save("))
        XCTAssertTrue(source.contains("ReaderProgressStore.read(bookId:"))
        XCTAssertTrue(source.contains("layoutManager.usedRect"))
        XCTAssertFalse(source.contains("/ 1200.0"))
        XCTAssertTrue(source.contains("return false"))
        XCTAssertTrue(source.contains("gestureRecognizerShouldBegin"))
    }

    func testMacReaderViewControllerSnapsAndPersistsProgress() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")

        XCTAssertTrue(source.contains("NSScrollView.didEndLiveScrollNotification"))
        XCTAssertTrue(source.contains("settings.readerLayout == .paginated"))
        XCTAssertTrue(source.contains("ReaderProgressStore.save("))
        XCTAssertTrue(source.contains("ReaderProgressStore.read(bookId:"))
    }
}
