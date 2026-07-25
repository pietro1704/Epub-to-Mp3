import XCTest

/// Source-contract tests for the slice-4 Book Detail flow: Library must
/// route through Book Detail (Read/Listen/Download) instead of opening the
/// reader directly, on both platforms. See
/// `docs/reader-spec-comparison.md` P0 gap #4.
final class BookDetailWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("EpubToMp3/\(relativePath)"),
            encoding: .utf8
        )
    }

    func testBookDetailScreenControllerIsNativeUIKitWithThreeActions() throws {
        let source = try source("Features/Library/Views/BookDetailScreenController.swift")

        XCTAssertTrue(source.contains("final class BookDetailScreenController: UIViewController"))
        XCTAssertFalse(source.contains("import SwiftUI"))
        XCTAssertFalse(source.contains("UIHostingController"))
        XCTAssertTrue(source.contains("tapRead"))
        XCTAssertTrue(source.contains("tapListen"))
        XCTAssertTrue(source.contains("tapDownload"))
    }

    func testMacBookDetailViewControllerIsNativeAppKitWithThreeActions() throws {
        let source = try source("Features/Library/Views/MacBookDetailViewController.swift")

        XCTAssertTrue(source.contains("final class MacBookDetailViewController: NSViewController"))
        XCTAssertFalse(source.contains("import SwiftUI"))
        XCTAssertFalse(source.contains("NSHostingController"))
        XCTAssertTrue(source.contains("tapRead"))
        XCTAssertTrue(source.contains("tapListen"))
        XCTAssertTrue(source.contains("tapDownload"))
    }

    func testLibraryScreenControllerOpensBookDetailNotReaderDirectly() throws {
        let source = try source("Features/Library/Views/LibraryScreenController.swift")

        XCTAssertTrue(source.contains("BookDetailScreenController("))
        XCTAssertTrue(source.contains("pushViewController(detail"))
        XCTAssertFalse(
            source.contains("ReaderSessionState.setCurrentlyReading(bookID: book.id)"),
            "Opening a book from the grid must go through Book Detail, not set the reader session directly."
        )
    }

    func testMacRootRoutesLibraryOpenThroughBookDetail() throws {
        let source = try source("App/MacAppKitRootController.swift")

        XCTAssertTrue(source.contains("showBookDetail(bookID: bookID)"))
        XCTAssertTrue(source.contains("MacBookDetailViewController("))
    }

    func testConvertScreenControllerAcceptsPreselectedFileURL() throws {
        let source = try source("Features/Conversion/Views/ConvertScreenController.swift")

        XCTAssertTrue(source.contains("preselectedFileURL: URL? = nil"))
        XCTAssertTrue(source.contains("viewModel.selectedFile = preselectedFileURL"))
    }
}
