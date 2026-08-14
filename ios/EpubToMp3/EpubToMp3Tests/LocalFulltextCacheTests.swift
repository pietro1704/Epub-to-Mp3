import XCTest
@testable import EpubToMp3

/// Tests for the durable `EbookFulltext` JSON cache. The cache is a
/// thin Swift wrapper around Application Support reader payloads
/// and is intentionally NOT replaced by `python_app.src.cache_manager`
/// — that module manages the conversion pipeline's parsed-text
/// checkpoints (different lifecycle, different keying, lives under
/// `PERSISTENT_ROOT/.cache/`).
final class LocalFulltextCacheTests: XCTestCase {

    private func uniqueId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    func testRoundTrip() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }

        let payload = EbookFulltext(
            jobId: id,
            bookTitle: "Foundation",
            bookAuthor: "Asimov",
            chapters: [
                .init(index: 1, name: "I",
                      text: "Hari Seldon stood watch.",
                      html: nil, css: nil, charCount: 24, segments: nil)
            ]
        )
        LocalFulltextCache.save(payload, bookId: id)
        let read = LocalFulltextCache.read(bookId: id)
        XCTAssertEqual(read?.bookTitle, "Foundation")
        XCTAssertEqual(read?.chapters.count, 1)
        XCTAssertEqual(read?.chapters.first?.text, "Hari Seldon stood watch.")
    }

    func testReadReturnsNilForUnknownBook() {
        XCTAssertNil(LocalFulltextCache.read(bookId: "no-such-book-\(UUID().uuidString)"))
    }

    func testEvictRemovesEntry() {
        let id = uniqueId()
        let payload = EbookFulltext(jobId: id, bookTitle: nil,
                                    bookAuthor: nil, chapters: [])
        LocalFulltextCache.save(payload, bookId: id)
        XCTAssertNotNil(LocalFulltextCache.read(bookId: id))
        LocalFulltextCache.evict(bookId: id)
        XCTAssertNil(LocalFulltextCache.read(bookId: id))
    }

    func testReaderPayloadUsesDurableApplicationSupportStorage() throws {
        let id = uniqueId()
        defer { LocalFulltextCache.evict(bookId: id) }

        let url = try XCTUnwrap(LocalFulltextCache.storageURL(bookId: id))
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        XCTAssertTrue(
            url.standardizedFileURL.path.hasPrefix(applicationSupport.standardizedFileURL.path + "/"),
            "Prepared reader content must survive the OS cache purge."
        )
    }
}
