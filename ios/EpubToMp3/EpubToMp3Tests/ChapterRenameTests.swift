import XCTest
#if os(macOS)
import AppKit
#endif
@testable import EpubToMp3

/// POC-EDITABLE-TOC-AND-FILENAME-COVER (1): the reader's contents list renames a chapter and
/// restores its automatic name. Rust owns the per-book overrides file.
@MainActor
final class ChapterRenameTests: XCTestCase {
    private func makeStore() throws -> (ChapterNameStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-names-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (ChapterNameStore(directory: root), root)
    }

    private func chapter(_ index: Int, _ name: String, html: String? = nil) -> EbookFulltext.Chapter {
        .init(index: index, name: name, text: "Synthetic text.", html: html, css: nil, charCount: 15, segments: nil)
    }

    func testRenamePersistsPerBookAndResets() throws {
        let (store, root) = try makeStore()
        XCTAssertEqual(store.names(bookID: "book/one"), [:])
        XCTAssertEqual(try store.set(bookID: "book/one", chapter: 2, name: "  The Arrival "), [2: "The Arrival"])
        let reopened = ChapterNameStore(directory: root)
        XCTAssertEqual(reopened.names(bookID: "book/one"), [2: "The Arrival"])
        XCTAssertEqual(reopened.names(bookID: "book/two"), [:])
        XCTAssertThrowsError(try reopened.set(bookID: "book/one", chapter: 1, name: "two\nlines"))
        XCTAssertEqual(try reopened.set(bookID: "book/one", chapter: 2, name: nil), [:])
    }

    func testTheChosenNameWinsEverywhereAndIsNeverWrittenIntoTheBookText() throws {
        let book = EbookFulltext(jobId: "job", bookTitle: "Synthetic", bookAuthor: nil, chapters: [
            chapter(1, "Automatic", html: "<h1>Printed heading</h1>"), chapter(2, "Chapter 2"),
        ])
        let renamed = book.applyingChapterNames([1: "Chapter 9", 2: "Epilogue"])
        XCTAssertEqual(renamed.chapters.map(\.displayTitle), ["Chapter 9", "Epilogue"])
        XCTAssertEqual(renamed.chapters.map(\.tocTitle), ["Chapter 9", "Epilogue"])
        let stored = try JSONDecoder().decode(EbookFulltext.self, from: JSONEncoder().encode(renamed))
        XCTAssertEqual(stored, book)
        XCTAssertEqual(renamed.applyingChapterNames([:]), book)
    }

    func testOnlyTheRowThatOpensTheChapterIsRenamed() {
        let chapters = [chapter(1, "One"), chapter(2, "Two")]
        let toc: [EbookFulltext.TocEntry] = [
            .init(title: "Part", level: 1, chapterIndex: 1, children: [
                .init(title: "Section inside", level: 2, chapterIndex: 1, children: []),
            ]),
            .init(title: "Second", level: 1, chapterIndex: 2, children: []),
        ]
        let book = EbookFulltext(jobId: "job", bookTitle: nil, bookAuthor: nil, chapters: chapters, toc: toc)
            .applyingChapterNames([1: "Renamed"])
        let rows = ReaderTocFlattener.rows(toc: book.toc, chapters: book.chapters)
        XCTAssertEqual(rows.map(\.title), ["Renamed", "Section inside", "Second"])
        XCTAssertEqual(rows.map(\.opensChapter), [true, false, true])
    }

    func testAnOpenReaderKeepsTheNameWhenTheParsedTextArrives() {
        let document = ReaderDocument()
        document.chapterNames = [1: "Mine"]
        document.fulltext = EbookFulltext(jobId: "job", bookTitle: nil, bookAuthor: nil, chapters: [chapter(1, "One")])
        XCTAssertEqual(document.tocRows.map(\.title), ["Mine"])
        document.chapterNames = [:]
        XCTAssertEqual(document.tocRows.map(\.title), ["One"])
    }

#if os(macOS)
    func testMacContentsRowOffersRenameAndRestore() async throws {
        let harness = try NativeReaderTestHarness(chapters: [NativeReaderTestHarness.chapter("Synthetic text.")])
        harness.installTeardown(in: self)
        let bookID = harness.book.id
        addTeardownBlock { _ = try? ChapterNameStore.shared.set(bookID: bookID, chapter: 1, name: nil) }
        let document = MacReaderDocument()
        document.currentBookId = bookID
        document.fulltext = EbookFulltext(jobId: "job", bookTitle: nil, bookAuthor: nil, chapters: [chapter(1, "One")])
        var published: [String] = []
        let renaming = ChapterRenaming(store: .shared, publish: { title, _ in published.append(title) })

        XCTAssertEqual(renaming.actions(for: document.tocRows[0], in: document).map(\.kind), [.rename])
        try renaming.apply("Mine", to: document.tocRows[0], in: document, bookID: bookID)
        XCTAssertEqual(document.tocRows.map(\.title), ["Mine"])
        XCTAssertEqual(renaming.actions(for: document.tocRows[0], in: document).map(\.kind), [.rename, .restore])
        try renaming.apply(nil, to: document.tocRows[0], in: document, bookID: bookID)
        XCTAssertEqual(document.tocRows.map(\.title), ["One"])
        XCTAssertEqual(published, ["Mine", "One"])
    }
#endif
}
