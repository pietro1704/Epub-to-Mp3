import XCTest
@testable import EpubToMp3

/// Verifies the macOS conversion importer copies user-selected documents into
/// an app-owned inbox instead of holding an external security scope open.
final class ConvertViewImportTests: XCTestCase {

    #if os(macOS)
    @MainActor
    func testImportForConversionCopiesIntoAppOwnedInbox() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("conv-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        let sourceDir = fm.temporaryDirectory
            .appendingPathComponent("conv-src-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sourceDir) }
        let source = sourceDir.appendingPathComponent("Book.epub", isDirectory: false)
        let payload = Data("epub-bytes".utf8)
        try payload.write(to: source)

        let durable = try ConvertViewModel.importForConversion(
            source,
            baseDirectory: base
        )

        // The conversion reads an app-owned copy, not the external original.
        XCTAssertNotEqual(durable.standardizedFileURL, source.standardizedFileURL)
        XCTAssertTrue(durable.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path))
        XCTAssertEqual(try Data(contentsOf: durable), payload)
        // The original selected file is preserved.
        XCTAssertTrue(fm.fileExists(atPath: source.path))
    }

    @MainActor
    func testImportForConversionRetainsOnlyActiveSelection() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("conv-inbox-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }

        let sourceDir = fm.temporaryDirectory
            .appendingPathComponent("conv-src-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sourceDir) }

        let first = sourceDir.appendingPathComponent("First.epub", isDirectory: false)
        try Data("first".utf8).write(to: first)
        let second = sourceDir.appendingPathComponent("Second.pdf", isDirectory: false)
        try Data("second".utf8).write(to: second)

        _ = try ConvertViewModel.importForConversion(first, baseDirectory: base)
        let durableSecond = try ConvertViewModel.importForConversion(second, baseDirectory: base)

        let contents = try fm.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents, ["Second.pdf"])
        XCTAssertEqual(try Data(contentsOf: durableSecond), Data("second".utf8))
    }
    #endif
}
