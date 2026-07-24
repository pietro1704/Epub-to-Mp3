import XCTest
@testable import EpubToMp3

/// Unit tests for the pure ordering/filtering model that backs the UIKit
/// library collection view. These guard the behavior parity with the
/// former inline `LibraryView.sorted` logic.
final class LibraryGridModelTests: XCTestCase {

    private func make(
        id: String,
        title: String,
        author: String? = nil,
        tags: [String] = [],
        addedAt: Date,
        lastOpenedAt: Date? = nil
    ) -> BookEntity {
        var book = BookEntity(
            id: id,
            title: title,
            author: author,
            bookmark: Data(),
            displayFilename: "\(id).epub",
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            lastChapterIndex: nil,
            lastPositionSeconds: nil,
            coverPNG: nil,
            lastJobId: nil,
            cachedOffline: false
        )
        book.tags = tags
        return book
    }

    private func date(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func testSortLastOpenedFallsBackToAddedAt() {
        let a = make(id: "a", title: "A", addedAt: date(100), lastOpenedAt: date(500))
        let b = make(id: "b", title: "B", addedAt: date(900), lastOpenedAt: nil)
        let c = make(id: "c", title: "C", addedAt: date(200), lastOpenedAt: date(300))
        let model = LibraryGridModel(books: [a, b, c], sortMode: .lastOpened)
        // b uses addedAt=900 (no lastOpened) → first; a=500; c=300.
        XCTAssertEqual(model.arrangedIdentifiers(), ["b", "a", "c"])
    }

    func testSortTitleIsLocalizedAscending() {
        let a = make(id: "a", title: "Zebra", addedAt: date(1))
        let b = make(id: "b", title: "apple", addedAt: date(1))
        let c = make(id: "c", title: "Éclair", addedAt: date(1))
        let model = LibraryGridModel(books: [a, b, c], sortMode: .title)
        XCTAssertEqual(model.arrangedIdentifiers(), ["b", "c", "a"])
    }

    func testSortAddedDateNewestFirst() {
        let a = make(id: "a", title: "A", addedAt: date(100))
        let b = make(id: "b", title: "B", addedAt: date(300))
        let c = make(id: "c", title: "C", addedAt: date(200))
        let model = LibraryGridModel(books: [a, b, c], sortMode: .addedDate)
        XCTAssertEqual(model.arrangedIdentifiers(), ["b", "c", "a"])
    }

    func testSearchMatchesTitleAuthorAndTagsCaseInsensitively() {
        let byTitle = make(id: "t", title: "The FOUNDATION", addedAt: date(3))
        let byAuthor = make(id: "au", title: "Other", author: "Isaac ASIMOV", addedAt: date(2))
        let byTag = make(id: "tg", title: "Nope", tags: ["Sci-Fi"], addedAt: date(1))
        let miss = make(id: "m", title: "Cooking", addedAt: date(4))
        let model = LibraryGridModel(
            books: [byTitle, byAuthor, byTag, miss],
            searchQuery: "  foun ",
            sortMode: .addedDate
        )
        XCTAssertEqual(model.arrangedIdentifiers(), ["t"])

        let tagModel = LibraryGridModel(books: [byTitle, byAuthor, byTag, miss], searchQuery: "sci-fi")
        XCTAssertEqual(tagModel.arrangedIdentifiers(), ["tg"])
    }

    func testTagFilterRestrictsToTaggedBooks() {
        let tagged = make(id: "x", title: "X", tags: ["fav"], addedAt: date(2))
        let untagged = make(id: "y", title: "Y", addedAt: date(1))
        let model = LibraryGridModel(books: [tagged, untagged], selectedTag: "fav", sortMode: .addedDate)
        XCTAssertEqual(model.arrangedIdentifiers(), ["x"])
    }

    func testEmptyQueryReturnsAll() {
        let a = make(id: "a", title: "A", addedAt: date(2))
        let b = make(id: "b", title: "B", addedAt: date(1))
        let model = LibraryGridModel(books: [a, b], searchQuery: "   ", sortMode: .addedDate)
        XCTAssertEqual(model.arrangedIdentifiers().count, 2)
    }

    func testSortModeLabelsAreAvailableToUIKitMenus() {
        for mode in LibraryGridModel.SortMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
        }
    }

    // MARK: - Layout metrics (shared by SwiftUI + UIKit renderers)

    func testColumnCountPacksAdaptiveTiles() {
        let m = LibraryGridLayoutMetrics()  // min 160, spacing 20, inset 20
        XCTAssertEqual(m.columnCount(forWidth: 400), 2)
        XCTAssertEqual(m.columnCount(forWidth: 800), 4)
    }

    func testColumnCountIsAtLeastOne() {
        let m = LibraryGridLayoutMetrics()
        XCTAssertEqual(m.columnCount(forWidth: 100), 1)
        XCTAssertEqual(m.columnCount(forWidth: 0), 1)
    }

    func testTileWidthClampsToMax() {
        let m = LibraryGridLayoutMetrics()
        // 2 columns in 1200pt would give wide tiles → clamp to 220.
        XCTAssertEqual(m.tileWidth(forWidth: 1200, columns: 2), 220, accuracy: 0.5)
        // 4 columns in 800pt → ~175pt, unclamped.
        XCTAssertEqual(m.tileWidth(forWidth: 800, columns: 4), 175, accuracy: 0.5)
    }
}
