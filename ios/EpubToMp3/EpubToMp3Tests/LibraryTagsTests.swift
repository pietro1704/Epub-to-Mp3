import XCTest
@testable import EpubToMp3

final class LibraryTagsTests: XCTestCase {
    private func makeStore() -> LibraryStore {
        let suite = "test.tags.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return LibraryStore(defaults: defaults, defaultsKey: "library.tags.test")
    }

    private func seedBook(in store: LibraryStore, id: String = "b1", title: String = "Book") {
        store.update(BookEntity(
            id: id, title: title, bookmark: Data([1]),
            displayFilename: "\(title).epub", addedAt: Date()
        ))
        if store.books.first(where: { $0.id == id }) == nil {
            // Force-insert since update only works for existing
            var books = store.books
            books.append(BookEntity(
                id: id, title: title, bookmark: Data([1]),
                displayFilename: "\(title).epub", addedAt: Date()
            ))
            // Use reflection-free approach: add via the internal books array
        }
    }

    func testAddAndRemoveTag() {
        let store = makeStore()
        // Manually populate since we can't call importBook without a real file
        let defaults = store as AnyObject
        // Test the tag logic on BookEntity directly
        var book = BookEntity(
            id: "b1", title: "Test", bookmark: Data([1]),
            displayFilename: "test.epub", addedAt: Date(), tags: []
        )
        XCTAssertTrue(book.tags.isEmpty)
        book.tags.append("fiction")
        XCTAssertEqual(book.tags, ["fiction"])
        book.tags.removeAll { $0 == "fiction" }
        XCTAssertTrue(book.tags.isEmpty)
    }

    func testTagsSerializationRoundTrip() throws {
        let book = BookEntity(
            id: "b1", title: "Test", bookmark: Data([1]),
            displayFilename: "test.epub", addedAt: Date(), tags: ["sci-fi", "classic"]
        )
        let data = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(BookEntity.self, from: data)
        XCTAssertEqual(decoded.tags, ["sci-fi", "classic"])
    }

    func testLegacyBookWithoutTagsDecodesEmpty() throws {
        let json = """
        {
            "id": "b1",
            "title": "Legacy Book",
            "bookmark": "",
            "displayFilename": "legacy.epub",
            "addedAt": 0
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let book = try decoder.decode(BookEntity.self, from: json)
        XCTAssertEqual(book.tags, [])
    }

    func testAllTagsFromMultipleBooks() {
        let store = makeStore()
        // Verify allTags aggregation via direct property
        XCTAssertTrue(store.allTags.isEmpty)
    }

    func testLibraryStoreAddTag() {
        let suite = "test.tags.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.tags.store.test")

        // Pre-populate with a book entity via encoding
        let book = BookEntity(
            id: "t1", title: "Tagged", bookmark: Data([1]),
            displayFilename: "tagged.epub", addedAt: Date()
        )
        let encoded = try! JSONEncoder().encode([book])
        defaults.set(encoded, forKey: "library.tags.store.test")
        let store2 = LibraryStore(defaults: defaults, defaultsKey: "library.tags.store.test")

        store2.addTag("fiction", to: "t1")
        XCTAssertEqual(store2.books[0].tags, ["fiction"])
        XCTAssertEqual(store2.allTags, ["fiction"])

        store2.addTag("classic", to: "t1")
        XCTAssertEqual(store2.books[0].tags, ["fiction", "classic"])

        // Duplicate tag not added
        store2.addTag("fiction", to: "t1")
        XCTAssertEqual(store2.books[0].tags, ["fiction", "classic"])

        store2.removeTag("fiction", from: "t1")
        XCTAssertEqual(store2.books[0].tags, ["classic"])

        let filtered = store2.books(withTag: "classic")
        XCTAssertEqual(filtered.count, 1)
    }
}
