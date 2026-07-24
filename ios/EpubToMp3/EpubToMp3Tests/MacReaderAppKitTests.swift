import XCTest

final class MacReaderAppKitTests: XCTestCase {
    func testMacRootUsesNativeControllers() throws {
        let root = try source("App/MacAppKitRootController.swift")
        let reader = try source("Features/Reader/Views/MacReaderViewController.swift")
        XCTAssertTrue(root.contains("NSSplitViewController"))
        XCTAssertTrue(root.contains("MacLibraryViewController"))
        XCTAssertTrue(reader.contains("NSTextView"))
        XCTAssertTrue(reader.contains("PDFView"))
        XCTAssertFalse(root.contains("NSHostingController"))
        XCTAssertFalse(reader.contains("NSHostingController"))
    }

    private func source(_ relativePath: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
