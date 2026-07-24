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
        let rootView = try String(contentsOf: root.appendingPathComponent("EpubToMp3/App/RootView.swift"), encoding: .utf8)
        let split = try String(contentsOf: root.appendingPathComponent("EpubToMp3/App/SplitViewRoot.swift"), encoding: .utf8)
        let mainReader = try String(contentsOf: root.appendingPathComponent("EpubToMp3/Features/Reader/Views/MainReaderView.swift"), encoding: .utf8)
        let bookOpen = try String(contentsOf: root.appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift"), encoding: .utf8)

        XCTAssertFalse(app.contains("RootView()"))
        XCTAssertFalse(rootView.contains("import SwiftUI"))
        XCTAssertFalse(split.contains("import SwiftUI"))
        XCTAssertFalse(mainReader.contains("import SwiftUI"))
        XCTAssertFalse(bookOpen.contains("UIHostingController"))
        XCTAssertFalse(bookOpen.contains("UIViewControllerRepresentable"))
    }

    func testProjectExcludesLegacySwiftUIScreensFromShippingTarget() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let spec = try String(
            contentsOf: root.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        for path in [
            "Features/Library/Views/LibraryView.swift",
            "Features/Conversion/Views/JobsListView.swift",
            "Features/Playback/Views/FullPlayerSheet.swift",
            "Features/Reader/Views/InstantReaderView.swift",
            "Features/Reader/Views/ReaderView.swift",
            "Features/Settings/Views/SettingsView.swift"
        ] {
            XCTAssertTrue(spec.contains("\"\(path)\""), "Legacy SwiftUI UI must stay out of the app target: \(path)")
        }
        XCTAssertTrue(spec.contains("App/MacAppKitRootController.swift"))
        XCTAssertTrue(spec.contains("Features/Reader/Views/BookOpenScreenController.swift"))
    }
}
