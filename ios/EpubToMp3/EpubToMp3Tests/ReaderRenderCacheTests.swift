import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderRenderCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ReaderAttributedRenderCache.removeAll()
    }

    override func tearDown() {
        ReaderAttributedRenderCache.removeAll()
        super.tearDown()
    }

    func testRenderKeySeparatesSameChapterIndexAcrossBooks() {
        let settingsKey = "font=serif|size=18|theme=light"
        let firstBook = ReaderAttributedRenderCache.key(
            namespace: "job-book-a", chapterID: "1", settingsKey: settingsKey
        )
        let secondBook = ReaderAttributedRenderCache.key(
            namespace: "job-book-b", chapterID: "1", settingsKey: settingsKey
        )

        XCTAssertNotEqual(firstBook, secondBook)

        let first = NSAttributedString(string: "Book A chapter 1")
        let second = NSAttributedString(string: "Book B chapter 1")
        ReaderAttributedRenderCache.store(first, for: firstBook)
        ReaderAttributedRenderCache.store(second, for: secondBook)

        XCTAssertEqual(
            ReaderAttributedRenderCache.value(for: firstBook)?.string,
            "Book A chapter 1"
        )
        XCTAssertEqual(
            ReaderAttributedRenderCache.value(for: secondBook)?.string,
            "Book B chapter 1"
        )
    }

    func testBookChapterRenderKeyIncludesBookNamespace() {
        let settings = AppSettings()
        let chapter = EbookFulltext.Chapter(
            index: 1,
            name: "Chapter 1",
            text: "body",
            html: nil,
            css: nil,
            charCount: 4,
            segments: nil
        )

        let first = BookChapterCell.renderKey(
            chapter: chapter,
            settings: settings,
            fontSize: 18,
            lineSpacing: 1.5,
            namespace: "job-book-a"
        )
        let second = BookChapterCell.renderKey(
            chapter: chapter,
            settings: settings,
            fontSize: 18,
            lineSpacing: 1.5,
            namespace: "job-book-b"
        )

        XCTAssertNotEqual(first, second)
    }

    func testReaderCancelsDuplicateNeighbourPrefetchWork() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("prefetchTask?.cancel()"))
        XCTAssertTrue(source.contains("prefetchTask = Task { @MainActor in"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled else { return }"))
    }
}
