import XCTest

/// Source-contract tests for TOC and in-chapter search wiring on both native
/// reader controllers. macOS follows EPUB hyperlinks for footnotes, like
/// Apple Books, so it intentionally has no separate footnotes button.
/// See `docs/reader-spec-comparison.md` P0 gap #1 (footnotes) and #3 (TOC).
final class ReaderTocFootnotesSearchWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readSourceFileIfAvailable(
            at: root.appendingPathComponent("EpubToMp3/\(relativePath)")
        )
    }

    func testBookOpenScreenControllerHasTocFootnotesAndSearch() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")

        XCTAssertTrue(source.contains("ReaderTocFlattener.rows("))
        XCTAssertTrue(source.contains("FootnotesSheetController"))
        XCTAssertTrue(source.contains("scrollRangeToVisible"))
    }

    func testMacReaderViewControllerHasTocAndSearchWithoutFootnotesButton() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")

        XCTAssertTrue(source.contains("ReaderTocFlattener.rows("))
        XCTAssertTrue(source.contains("scrollRangeToVisible"))
        XCTAssertFalse(source.contains("accessibilityIdentifier = \"reader.footnotes\""))
    }

    func testSharedTocControllerExposesChapterDownloadControls() throws {
        let source = try source("Features/Reader/Views/TocScreenController.swift")

        XCTAssertTrue(source.contains("reader.toc.download."))
        XCTAssertTrue(source.contains("DownloadManager.locallyDownloadedIndices"))
        XCTAssertTrue(source.contains("enqueueSelected"))
        XCTAssertTrue(source.contains("enqueueAll"))
    }
}
