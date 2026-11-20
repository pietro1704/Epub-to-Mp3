import Foundation
import XCTest
@testable import EpubToMp3

/// Pins the persisted `bookmarks.v1` format. Highlights written by an older build
/// must keep decoding and must be written back unchanged.
final class BookmarkStoreFormatTests: XCTestCase {
    private let literal = """
    [{"id":"11111111-1111-1111-1111-111111111111","bookId":"book","chapterIndex":2,
      "chapterTitle":"Chapter Three","startChar":10,"endChar":20,"selectedText":"a highlight",
      "note":"kept","color":"pink","createdAt":700000000},
     {"id":"22222222-2222-2222-2222-222222222222","bookId":"book","chapterIndex":0,
      "chapterTitle":"","startChar":0,"endChar":0,"selectedText":"",
      "color":"yellow","createdAt":700000001}]
    """

    func testOldRecordsDecodeAndTheStoreKeepsTheKeyAndFields() throws {
        let suite = "BookmarkStoreFormat.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(literal.utf8), forKey: "bookmarks.v1")

        let store = BookmarkStore(defaults: defaults)
        XCTAssertEqual(store.bookmarks.count, 2)
        let first = try XCTUnwrap(store.bookmarks.first)
        XCTAssertEqual(first.chapterTitle, "Chapter Three", "stored titles are never rewritten")
        XCTAssertEqual(first.color, .pink)
        XCTAssertEqual(first.note, "kept")
        XCTAssertNil(store.bookmarks[1].note)

        store.addBookmark(bookId: "book", chapterIndex: 1, chapterTitle: "T", selectedText: "x")
        let written = try XCTUnwrap(defaults.data(forKey: "bookmarks.v1"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [[String: Any]])
        XCTAssertEqual(object.count, 3)
        XCTAssertEqual(Set(object[0].keys),
            ["id", "bookId", "chapterIndex", "chapterTitle", "startChar", "endChar", "selectedText", "note", "color", "createdAt"])
        XCTAssertEqual(object[0]["chapterTitle"] as? String, "Chapter Three")
        XCTAssertEqual(HighlightColor.allCases.map(\.rawValue), ["yellow", "blue", "green", "pink", "orange"])
    }
}
