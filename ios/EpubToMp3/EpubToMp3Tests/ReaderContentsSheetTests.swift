#if os(iOS)
import UIKit
import XCTest
@testable import EpubToMp3

@MainActor
final class ReaderContentsSheetTests: XCTestCase {
    func testContentsKeepsSourceChapterIdentityAndDoesNotSelectUnresolvedRows() throws {
        let rows = [
            ReaderTocRow(title: "Part", level: 0, chapterIndex: nil),
            ReaderTocRow(title: "Chapter nine", level: 1, chapterIndex: 8),
            ReaderTocRow(title: "Chapter three", level: 1, chapterIndex: 2),
        ]
        var selected: [Int] = []
        let sheet = try makeContents(rows: rows, readingIndex: 8) { selected.append($0) }
        sheet.loadViewIfNeeded()
        XCTAssertEqual(sheet.tableView(sheet.tableView, numberOfRowsInSection: 0), 3)
        XCTAssertTrue(selected.isEmpty, "Opening contents must remain a browsing action")
        sheet.tableView(sheet.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertTrue(selected.isEmpty)
        sheet.tableView(sheet.tableView, didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(selected, [2], "Row order must not replace source chapter identity")
    }

    func testContentsMarksTheActualFocusedChapterWithoutAutoselectingIt() throws {
        let rows = [ReaderTocRow(title: "Later", level: 0, chapterIndex: 11)]
        let sheet = try makeContents(rows: rows, readingIndex: 11) { _ in
            XCTFail("Presenting the focused row must not navigate or autoplay")
        }
        sheet.loadViewIfNeeded()
        let cell = sheet.tableView(sheet.tableView, cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))
        XCTAssertTrue(cell.accessibilityTraits.contains(.button))
    }

    private func makeContents(
        rows: [ReaderTocRow], readingIndex: Int, onSelect: @escaping (Int) -> Void
    ) throws -> TocScreenController {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reader-contents-\(UUID().uuidString)"))
        let book = BookEntity(id: "contents-fixture", title: "Contents", bookmark: Data(),
                              displayFilename: "contents.epub", addedAt: Date())
        let navigation = ReaderContentsPresentation.makeSheet(
            book: book, rows: rows, library: LibraryStore(defaults: defaults),
            settings: AppSettings(), snapshot: nil, playingIndex: nil, readingIndex: readingIndex, onSelect: onSelect)
        return try XCTUnwrap(navigation.topViewController as? TocScreenController)
    }
}
#endif
