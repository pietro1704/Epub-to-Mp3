import XCTest

final class ReaderAccessibilityContractTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testNativeReadersExposeStableAccessibilityIdentifiers() throws {
        let ios = try source("Features/Reader/Views/BookOpenScreenController.swift")
        let mac = try source("Features/Reader/Views/MacReaderViewController.swift")
        for identifier in ["reader.content", "reader.toc", "reader.search", "reader.footnotes"] {
            XCTAssertTrue(ios.contains(identifier))
            XCTAssertTrue(mac.contains(identifier))
        }
    }
}
