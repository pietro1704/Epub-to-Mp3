import XCTest

/// Source-contract tests for the slice-3 selection → bookmark/highlight/note
/// wiring: both native reader controllers must expose the two actions over
/// the current text selection and persist through `BookmarkStore`, and must
/// repaint saved highlights on chapter (re)load via `ReaderTextHighlight`.
/// See `docs/reader-spec-comparison.md` P0 gap #3.
final class ReaderSelectionWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("EpubToMp3/\(relativePath)"),
            encoding: .utf8
        )
    }

    func testBookOpenScreenControllerExposesSelectionActionsAndRepaint() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")

        XCTAssertTrue(source.contains("UITextViewDelegate"))
        XCTAssertTrue(source.contains("editMenuForTextIn range: NSRange"))
        XCTAssertTrue(source.contains("bookmarkStore.addBookmark("))
        XCTAssertTrue(source.contains("repaintSavedHighlights"))
        XCTAssertTrue(source.contains("ReaderTextHighlight.range("))
    }

    func testMacReaderViewControllerExposesSelectionActionsAndRepaint() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")

        XCTAssertTrue(source.contains("onBuildSelectionMenu"))
        XCTAssertTrue(source.contains("bookmarkStore.addBookmark("))
        XCTAssertTrue(source.contains("repaintSavedHighlights"))
        XCTAssertTrue(source.contains("ReaderTextHighlight.range("))
    }
}
