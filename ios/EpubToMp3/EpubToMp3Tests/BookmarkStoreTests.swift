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

    /// Verifies that corrupt data on disk does not get overwritten with an
    /// empty array — the store must refuse to persist until it has
    /// successfully decoded the stored bookmarks at least once.
    func testCorruptDataNotOverwritten() {
        let suite = "test.bookmarks.corrupt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let key = "bookmarks.corrupt.test"

        // 1. Write valid bookmarks via a normal store.
        let good = BookmarkStore(defaults: defaults, storageKey: key)
        good.addBookmark(bookId: "b1", chapterIndex: 1, chapterTitle: "Ch 1")
        XCTAssertEqual(good.bookmarks.count, 1)

        // 2. Corrupt the data on disk.
        defaults.set(Data("{invalid json".utf8), forKey: key)

        // 3. Open a new store — decode should fail, bookmarks empty.
        let broken = BookmarkStore(defaults: defaults, storageKey: key)
        XCTAssertTrue(broken.bookmarks.isEmpty, "Decode should fail → empty in-memory list")

        // 4. Attempt a mutation — persist must be blocked so the corrupt
        //    (but potentially recoverable) data is not overwritten.
        broken.addBookmark(bookId: "b2", chapterIndex: 1, chapterTitle: "Ch 1")
        // In-memory list grows, but disk should still hold the corrupt blob.
        XCTAssertEqual(broken.bookmarks.count, 1) // in-memory has the new one

        // 5. Verify the on-disk data is still the corrupt blob, NOT a
        //    freshly encoded empty or single-element array.
        let raw = defaults.data(forKey: key)!
        let rawString = String(data: raw, encoding: .utf8)!
        XCTAssertTrue(rawString.contains("{invalid json"),
                      "Corrupt data must survive — persist should have been blocked")
    }
}
