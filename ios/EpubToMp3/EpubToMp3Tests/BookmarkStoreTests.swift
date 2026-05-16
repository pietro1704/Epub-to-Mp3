import XCTest
@testable import EpubToMp3

final class BookmarkStoreTests: XCTestCase {
    private func makeStore() -> BookmarkStore {
        let suite = "test.bookmarks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return BookmarkStore(defaults: defaults, storageKey: "bookmarks.test")
    }

    func testAddAndRetrieveBookmark() {
        let store = makeStore()
        store.addBookmark(bookId: "b1", chapterIndex: 3, chapterTitle: "Ch 3")
        XCTAssertEqual(store.bookmarks(for: "b1").count, 1)
        XCTAssertTrue(store.hasBookmark(bookId: "b1", chapterIndex: 3))
        XCTAssertFalse(store.hasBookmark(bookId: "b1", chapterIndex: 1))
    }

    func testAddHighlight() {
        let store = makeStore()
        store.addBookmark(
            bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1",
            startChar: 10, endChar: 50,
            selectedText: "Hello world", color: .blue
        )
        let highlights = store.highlights(for: "b1")
        XCTAssertEqual(highlights.count, 1)
        XCTAssertEqual(highlights[0].selectedText, "Hello world")
        XCTAssertEqual(highlights[0].color, .blue)
        XCTAssertTrue(highlights[0].isHighlight)
    }

    func testRemoveBookmark() {
        let store = makeStore()
        let bm = store.addBookmark(bookId: "b1", chapterIndex: 2, chapterTitle: "Ch 2")
        XCTAssertEqual(store.bookmarks.count, 1)
        store.remove(id: bm.id)
        XCTAssertEqual(store.bookmarks.count, 0)
    }

    func testUpdateNote() {
        let store = makeStore()
        let bm = store.addBookmark(bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1")
        XCTAssertNil(store.bookmarks[0].note)
        store.updateNote(id: bm.id, note: "My note")
        XCTAssertEqual(store.bookmarks[0].note, "My note")
    }

    func testUpdateColor() {
        let store = makeStore()
        let bm = store.addBookmark(
            bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1",
            startChar: 0, endChar: 5, selectedText: "text", color: .yellow
        )
        store.updateColor(id: bm.id, color: .green)
        XCTAssertEqual(store.bookmarks[0].color, .green)
    }

    func testRemoveAllForBook() {
        let store = makeStore()
        store.addBookmark(bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1")
        store.addBookmark(bookId: "b1", chapterIndex: 2, chapterTitle: "Ch 2")
        store.addBookmark(bookId: "b2", chapterIndex: 1, chapterTitle: "Ch 1")
        XCTAssertEqual(store.bookmarks.count, 3)
        store.removeAll(for: "b1")
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertEqual(store.bookmarks[0].bookId, "b2")
    }

    func testPersistenceRoundTrip() {
        let suite = "test.bookmarks.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let key = "bookmarks.persist.test"

        let store1 = BookmarkStore(defaults: defaults, storageKey: key)
        store1.addBookmark(bookId: "b1", chapterIndex: 5, chapterTitle: "Ch 5", note: "saved")

        let store2 = BookmarkStore(defaults: defaults, storageKey: key)
        XCTAssertEqual(store2.bookmarks.count, 1)
        XCTAssertEqual(store2.bookmarks[0].chapterIndex, 5)
        XCTAssertEqual(store2.bookmarks[0].note, "saved")
    }

    func testFilterByChapter() {
        let store = makeStore()
        store.addBookmark(bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1")
        store.addBookmark(bookId: "b1", chapterIndex: 2, chapterTitle: "Ch 2")
        store.addBookmark(bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1",
                          startChar: 5, endChar: 10, selectedText: "hi")
        let ch1 = store.bookmarks(for: "b1", chapterIndex: 1)
        XCTAssertEqual(ch1.count, 2)
        let ch2 = store.bookmarks(for: "b1", chapterIndex: 2)
        XCTAssertEqual(ch2.count, 1)
    }

    func testPageBookmarksVsHighlights() {
        let store = makeStore()
        store.addBookmark(bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1")
        store.addBookmark(bookId: "b1", chapterIndex: 2, chapterTitle: "Ch 2",
                          startChar: 0, endChar: 5, selectedText: "text")
        XCTAssertEqual(store.pageBookmarks(for: "b1").count, 1)
        XCTAssertEqual(store.highlights(for: "b1").count, 1)
    }
}
