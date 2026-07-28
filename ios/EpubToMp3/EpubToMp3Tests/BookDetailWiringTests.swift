import XCTest

/// Source-contract tests for the native Book Detail implementation retained
/// for iOS and legacy macOS documents. The macOS library now opens the reader
/// directly, matching the iOS reading flow.
final class BookDetailWiringTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try readSourceFileIfAvailable(
            at: root.appendingPathComponent("EpubToMp3/\(relativePath)")
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

        XCTAssertTrue(source.contains("gridController.onOpen"))
        XCTAssertTrue(source.contains("ReaderSessionState.setCurrentlyReading(bookID: book.id)"))
    }

    func testMacRootRoutesLibraryOpenDirectlyToReader() throws {
        let source = try source("App/MacAppKitRootController.swift")

        XCTAssertTrue(source.contains("showReader(bookID: bookID)"))
        XCTAssertFalse(source.contains("onOpenBook: { [weak self] bookID in self?.showBookDetail(bookID: bookID) }"))
    }

    func testConvertScreenControllerAcceptsPreselectedFileURL() throws {
        let source = try source("Features/Conversion/Views/ConvertScreenController.swift")

        XCTAssertTrue(source.contains("preselectedFileURL: URL? = nil"))
        XCTAssertTrue(source.contains("viewModel.selectedFile = preselectedFileURL"))
    }
}
