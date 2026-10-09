import Foundation
import XCTest
@testable import EpubToMp3

private final class ChapterSourceChangeProbe: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var target: URL?
    func arm(_ url: URL) { lock.lock(); target = url; lock.unlock() }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        let change = path.hasSuffix(".archive") ? target : nil
        if change != nil { target = nil }
        lock.unlock()
        if let change { try Data("source changed during archive read".utf8).write(to: change, options: .atomic) }
        return try super.attributesOfItem(atPath: path)
    }
}

final class PreparedReaderChapterStoreTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-chapter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("fulltext.plist")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func payload() -> EbookFulltext {
        EbookFulltext(jobId: "book", bookTitle: "Title", bookAuthor: "Author", chapters: [
            .init(index: 1, name: "Chapter", sourcePath: "chapter.xhtml", text: "Reader text",
                  speechText: "Speech", html: "<b>Reader</b> text", css: "b {color:red}", charCount: 11,
                  segments: [.init(id: "sentence", text: "Reader text", startMs: 0, endMs: 100)],
                  resources: [.init(href: "image.png", mediaType: "image/png", dataBase64: "AA==")],
                  footnotes: [.init(number: "1", text: "Note")], contentKind: "text")
        ])
    }
    private func save(_ value: EbookFulltext) throws -> Data {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let bytes = try encoder.encode(value)
        try bytes.write(to: source, options: .atomic)
        return bytes
    }
    func testChapterRoundTripRetainsCompletePayloadAndSourceBytes() async throws {
        let value = payload(); let bytes = try save(value)
        let directory = root.appendingPathComponent("chapters")
        let store = PreparedReaderChapterStore(directory: directory)
        try await store.write(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        let reopened = PreparedReaderChapterStore(directory: directory)
        let restored = await reopened.read(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        let chapter = try XCTUnwrap(restored)
        XCTAssertEqual(chapter.chapter, value.chapters[0])
        XCTAssertEqual(chapter.title, value.bookTitle)
        XCTAssertEqual(chapter.author, value.bookAuthor)
        XCTAssertEqual(chapter.chapterCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let wrong = await reopened.read(bookID: "other", chapterOrdinal: 0, fulltextURL: source)
        XCTAssertNil(wrong)
    }
    func testChangedSourceAndWrongOrdinalAreMisses() async throws {
        _ = try save(payload())
        let store = PreparedReaderChapterStore(directory: root.appendingPathComponent("chapters"))
        try await store.write(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        let wrong = await store.read(bookID: "book", chapterOrdinal: 1, fulltextURL: source)
        XCTAssertNil(wrong)
        try Data("changed source".utf8).write(to: source, options: .atomic)
        let stale = await store.read(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        XCTAssertNil(stale)
    }
    func testUnsafeAndOversizedSourceRejectedWithoutModification() async throws {
        let bytes = try save(payload())
        let link = root.appendingPathComponent("linked.plist")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let store = PreparedReaderChapterStore(directory: root.appendingPathComponent("chapters"), maximumSourceBytes: 1)
        do { try await store.write(bookID: "book", chapterOrdinal: 0, fulltextURL: source); XCTFail("Oversized source accepted") }
        catch { }
        let linked = await store.read(bookID: "book", chapterOrdinal: 0, fulltextURL: link)
        XCTAssertNil(linked)
        let normal = PreparedReaderChapterStore(directory: root.appendingPathComponent("valid-chapters"))
        try await normal.write(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        let symlinked = await normal.read(bookID: "book", chapterOrdinal: 0, fulltextURL: link)
        XCTAssertNil(symlinked)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testCorruptProjectionAndInvalidOrdinalFailClosed() async throws {
        let bytes = try save(payload())
        let directory = root.appendingPathComponent("chapters")
        let store = PreparedReaderChapterStore(directory: directory)
        do { try await store.write(bookID: "book", chapterOrdinal: 2, fulltextURL: source); XCTFail("Invalid ordinal accepted") }
        catch { }
        try await store.write(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        let archive = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("corrupt projection".utf8).write(to: archive, options: .atomic)
        let corrupt = await store.read(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        XCTAssertNil(corrupt)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testSourceChangedDuringArchiveAwaitCannotReturnStaleChapter() async throws {
        let bytes = try save(payload())
        let probe = ChapterSourceChangeProbe()
        let store = PreparedReaderChapterStore(directory: root.appendingPathComponent("chapters"), fileManager: probe)
        try await store.write(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        probe.arm(source)
        let stale = await store.read(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        XCTAssertNil(stale)
        XCTAssertNotEqual(try Data(contentsOf: source), bytes)
        try bytes.write(to: source, options: .atomic)
        let recovered = await store.read(bookID: "book", chapterOrdinal: 0, fulltextURL: source)
        XCTAssertNotNil(recovered)
    }
}
