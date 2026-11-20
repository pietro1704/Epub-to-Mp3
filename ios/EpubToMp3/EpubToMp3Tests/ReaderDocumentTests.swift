#if os(macOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderDocumentTests: XCTestCase {
    func testLoadIsCurrentOnlyForItsGenerationAndBook() {
        let document = MacReaderDocument()
        document.currentBookId = "book"
        XCTAssertTrue(document.isActiveLoad(document.loadGeneration, bookID: "book"))
        XCTAssertFalse(document.isActiveLoad(UUID(), bookID: "book"), "an older generation is stale")
        XCTAssertFalse(document.isActiveLoad(document.loadGeneration, bookID: "other"), "another book is stale")
        document.currentBookId = nil
        XCTAssertFalse(document.isActiveLoad(document.loadGeneration, bookID: "book"))
    }

    func testMacLoadInACancelledTaskIsNeverActive() async {
        let document = MacReaderDocument()
        document.currentBookId = "book"
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return document.isActiveLoad(document.loadGeneration, bookID: "book")
        }
        task.cancel()
        let active = await task.value
        XCTAssertFalse(active)
    }

    func testSharedPredicateIgnoresCancellationLikeIOS() async {
        let generation = UUID()
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return ReaderDocument.isCurrentLoad(
                generation: generation, current: generation, bookID: "book", currentBookID: "book")
        }
        task.cancel()
        let current = await task.value
        XCTAssertTrue(current)
    }

    func testChapterComesFromFulltextOrTheActivePreparedChapter() {
        let document = ReaderDocument()
        XCTAssertNil(document.chapter(at: 0))
        let chapter = EbookFulltext.Chapter(index: 0, name: "One", text: "Text", html: nil,
                                            css: nil, charCount: 4, segments: nil)
        document.fulltext = EbookFulltext(jobId: "book", bookTitle: "Title", bookAuthor: nil, chapters: [chapter])
        XCTAssertEqual(document.chapter(at: 0)?.name, "One")
        XCTAssertNil(document.chapter(at: 1))
        XCTAssertEqual(document.tocRows.count, 1)
    }
}
#endif
