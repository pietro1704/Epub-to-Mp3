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

    func testNativeEntryDoesNotDependOnLegacySwiftUIRoots() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("EpubToMp3/App/EpubToMp3App.swift"), encoding: .utf8)
        let bookOpen = try String(contentsOf: root.appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift"), encoding: .utf8)

        XCTAssertTrue(app.contains("MacAppKitRootController"))
        XCTAssertFalse(bookOpen.contains("UIHostingController"))
        XCTAssertFalse(bookOpen.contains("UIViewControllerRepresentable"))
    }

    func testLegacySwiftUIScreensAreRemovedFromTheAppleAppSourceTree() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for path in [
            "EpubToMp3/Features/Library/Views/LibraryView.swift",
            "EpubToMp3/Features/Conversion/Views/JobsListView.swift",
            "EpubToMp3/Features/Playback/Views/FullPlayerSheet.swift",
            "EpubToMp3/Features/Reader/Views/InstantReaderView.swift",
            "EpubToMp3/Features/Reader/Views/ReaderView.swift",
            "EpubToMp3/Features/Settings/Views/SettingsView.swift",
            "EpubToMp3/Features/Reader/Views/InstantReaderScreenController.swift"
        ] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                           "Legacy SwiftUI source must be removed: \(path)")
        }
    }
}
