import XCTest

final class ReaderSearchScopeTests: XCTestCase {
    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3")
        return try readSourceFileIfAvailable(at: root.appendingPathComponent(relativePath))
    }

    func testIOSSearchWalksAllChapters() throws {
        let source = try source("Features/Reader/Views/BookOpenScreenController.swift")
        XCTAssertTrue(source.contains("chapters.indices.dropFirst(selectedChapter)"))
        XCTAssertTrue(source.contains("showChapter(chapterIndex)"))
    }

    func testMacSearchWalksAllChapters() throws {
        let source = try source("Features/Reader/Views/MacReaderViewController.swift")
        XCTAssertTrue(source.contains("chapters.indices.dropFirst(selectedChapter)"))
        XCTAssertTrue(source.contains("showChapter(chapterIndex)"))
    }
}
