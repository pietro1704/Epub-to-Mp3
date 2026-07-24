import XCTest

final class AppKitMigrationTests: XCTestCase {
    func testMacLibraryControllerIsNativeAppKitAndDoesNotHostSwiftUI() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Library/Views/MacLibraryViewController.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("final class MacLibraryViewController: NSViewController"))
        XCTAssertTrue(source.contains("NSCollectionViewDataSource"))
        XCTAssertTrue(source.contains("NSOpenPanel()"))
        XCTAssertFalse(source.contains("import SwiftUI"))
        XCTAssertFalse(source.contains("NSHostingController"))
    }

    func testLibraryGridModelDoesNotDependOnLibraryView() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Library/Models/LibraryGridModel.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("LibraryView"))
        XCTAssertTrue(source.contains("enum SortMode"))
    }

    func testMacShellAndReaderUseNativeControllers() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let shell = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/App/MacAppKitRootController.swift"
            ), encoding: .utf8
        )
        let reader = try String(
            contentsOf: root.appendingPathComponent(
                "EpubToMp3/Features/Reader/Views/MacReaderViewController.swift"
            ), encoding: .utf8
        )
        let app = try String(
            contentsOf: root.appendingPathComponent("EpubToMp3/App/EpubToMp3App.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(shell.contains("NSSplitViewController"))
        XCTAssertTrue(shell.contains("MacLibraryViewController"))
        XCTAssertTrue(reader.contains("NSTextView"))
        XCTAssertTrue(reader.contains("PDFView"))
        XCTAssertFalse(shell.contains("NSHostingController"))
        XCTAssertFalse(reader.contains("NSHostingController"))
        XCTAssertTrue(app.contains("NSApplicationDelegate"))
        XCTAssertTrue(app.contains("MacAppKitRootController"))
        XCTAssertFalse(app.contains("WindowGroup"))
    }
}
