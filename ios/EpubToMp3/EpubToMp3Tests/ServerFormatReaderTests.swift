import Foundation
import XCTest
@testable import EpubToMp3

/// Exercises the local reader path that replaced the retired upload contract.
final class LocalReaderFormatTests: XCTestCase {
    func testLocalEPUBPreparationRemainsReadableFromDiskWithoutSource() async throws {
        let source = try EpubFixture.createWithChapter(
            chapterTitle: "Local chapter", body: "Readable <b>offline</b> content."
        )
        let bookID = "local-reader-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: source)
            LocalFulltextCache.evict(bookId: bookID)
        }

        let prepared = await EpubFallbackParser.parseAsync(url: source, bookId: bookID)
        XCTAssertEqual(prepared.jobId, bookID)
        XCTAssertEqual(prepared.bookTitle, EpubFixture.title)
        XCTAssertEqual(prepared.bookAuthor, EpubFixture.author)
        XCTAssertEqual(prepared.chapters.count, 1)
        XCTAssertEqual(prepared.chapters.first?.name, "Local chapter")
        XCTAssertTrue(prepared.chapters.first?.text.contains("Readable offline content.") == true)
        XCTAssertTrue(prepared.chapters.first?.html?.contains("<b>offline</b>") == true)

        LocalFulltextCache.save(prepared, bookId: bookID)
        LocalFulltextCache.evictInMemoryPayload(bookId: bookID)
        try FileManager.default.removeItem(at: source)

        let restored = try XCTUnwrap(LocalFulltextCache.read(bookId: bookID))
        XCTAssertEqual(restored, prepared)
    }

    func testUnreadableLocalEPUBDoesNotFabricateReaderContent() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-reader-\(UUID().uuidString).epub")
        try Data("This is not an EPUB archive.".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let prepared = await EpubFallbackParser.parseAsync(url: source, bookId: "invalid-local-book")

        XCTAssertEqual(prepared.jobId, "invalid-local-book")
        XCTAssertTrue(prepared.chapters.isEmpty)
    }

    #if os(macOS)
    func testMacReaderAdapterPreservesLocalEPUBContent() async throws {
        let source = try EpubFixture.createWithChapter(
            chapterTitle: "Mac local chapter", body: "Read this book without an upload."
        )
        defer { try? FileManager.default.removeItem(at: source) }

        let prepared = try await MacEpubParser.parse(at: source, bookId: "mac-local-book")

        XCTAssertEqual(prepared.jobId, "mac-local-book")
        XCTAssertEqual(prepared.bookTitle, EpubFixture.title)
        XCTAssertEqual(prepared.chapters.count, 1)
        XCTAssertEqual(prepared.chapters.first?.name, "Mac local chapter")
        XCTAssertTrue(prepared.chapters.first?.text.contains("Read this book without an upload.") == true)
    }
    #endif
}
