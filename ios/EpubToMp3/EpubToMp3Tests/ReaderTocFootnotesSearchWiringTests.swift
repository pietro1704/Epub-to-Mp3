import XCTest

/// Source-contract tests for the slice-3 TOC hierarchy, footnotes sheet,
/// and in-chapter search wiring on both native reader controllers.
/// See `docs/reader-spec-comparison.md` P0 gap #1 (footnotes) and #3 (TOC).
final class ReaderTocFootnotesSearchWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("EpubToMp3/\(relativePath)"),
            encoding: .utf8
        )
    }

    func testBookOpenScreenControllerHasTocFootnotesAndSearch() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")

        XCTAssertTrue(source.contains("ReaderTocFlattener.rows("))
        XCTAssertTrue(source.contains("FootnotesSheetController"))
        XCTAssertTrue(source.contains("scrollRangeToVisible"))
    }

    func testMacReaderViewControllerHasTocFootnotesAndSearch() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")

        XCTAssertTrue(source.contains("ReaderTocFlattener.rows("))
        XCTAssertTrue(source.contains("showFootnotes"))
        XCTAssertTrue(source.contains("scrollRangeToVisible"))
    }
}
