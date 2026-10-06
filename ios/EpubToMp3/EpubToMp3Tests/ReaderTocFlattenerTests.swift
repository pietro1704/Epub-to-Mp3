import XCTest
@testable import EpubToMp3

final class ReaderTocFlattenerTests: XCTestCase {
    private func chapter(_ index: Int, name: String) -> EbookFulltext.Chapter {
        EbookFulltext.Chapter(index: index, name: name, text: "text", html: nil, css: nil, charCount: 4, segments: nil)
    }

    func testFallsBackToFlatChapterListWhenTocIsNilOrEmpty() {
        let chapters = [chapter(1, name: "One"), chapter(2, name: "Two")]

        let rows = ReaderTocFlattener.rows(toc: nil, chapters: chapters)

        XCTAssertEqual(rows.map(\.title), ["One", "Two"])
        XCTAssertEqual(rows.map(\.level), [0, 0])
        XCTAssertEqual(rows.map(\.chapterIndex), [0, 1])

        XCTAssertEqual(ReaderTocFlattener.rows(toc: [], chapters: chapters).count, 2)
    }

    func testFlattensNestedTocWithIndentLevelsAndConvertsToZeroBasedChapterIndex() {
        let toc: [EbookFulltext.TocEntry] = [
            EbookFulltext.TocEntry(title: "Part One", level: 1, chapterIndex: nil, children: [
                EbookFulltext.TocEntry(title: "Chapter 1", level: 2, chapterIndex: 1, children: []),
                EbookFulltext.TocEntry(title: "Chapter 2", level: 2, chapterIndex: 2, children: []),
            ]),
        ]
        let chapters = [chapter(1, name: "Chapter 1"), chapter(2, name: "Chapter 2")]

        let rows = ReaderTocFlattener.rows(toc: toc, chapters: chapters)

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].title, "Part One")
        XCTAssertEqual(rows[0].level, 0)
        XCTAssertNil(rows[0].chapterIndex)
        XCTAssertEqual(rows[1].level, 1)
        XCTAssertEqual(rows[1].chapterIndex, 0) // server's 1-based → 0-based array index
        XCTAssertEqual(rows[2].chapterIndex, 1)
    }

    func testTocEntryWithNoResolvedChapterIndexStaysNil() {
        let toc: [EbookFulltext.TocEntry] = [
            EbookFulltext.TocEntry(title: "Orphan Note", level: 1, chapterIndex: nil, children: []),
        ]

        let rows = ReaderTocFlattener.rows(toc: toc, chapters: [chapter(1, name: "Chapter 1")])

        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].chapterIndex)
    }
}
