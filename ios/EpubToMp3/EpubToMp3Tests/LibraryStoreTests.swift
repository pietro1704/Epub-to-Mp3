import XCTest
@testable import EpubToMp3

final class LibraryStoreTests: XCTestCase {

    private func ephemeralStore() -> (LibraryStore, UserDefaults, String) {
        let suite = "library.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        return (store, defaults, suite)
    }

    func testStoreStartsEmpty() {
        let (store, _, suite) = ephemeralStore()
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(store.loadError)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testContentHashIsStableAcrossInvocations() throws {
        // Write a deterministic file and ensure the SHA-256-based id is
        // identical across invocations — required for the de-dup path.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-test-\(UUID().uuidString).epub")
        let payload = Data(repeating: 0x42, count: 8 * 1024)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let h1 = try LibraryStore.contentHash(of: tmp)
        let h2 = try LibraryStore.contentHash(of: tmp)
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 32)
        XCTAssertEqual(h1, h1.lowercased())
    }

    func testContentHashChangesWhenFileChanges() throws {
        let dir = FileManager.default.temporaryDirectory
        let a = dir.appendingPathComponent("a-\(UUID().uuidString).epub")
        let b = dir.appendingPathComponent("b-\(UUID().uuidString).epub")
        try Data(repeating: 0x01, count: 1024).write(to: a)
        try Data(repeating: 0x02, count: 1024).write(to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        XCTAssertNotEqual(try LibraryStore.contentHash(of: a),
                          try LibraryStore.contentHash(of: b))
    }

    func testImportThenRemoveRoundtrip() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Build a tiny EPUB-shaped file so importBook has something
        // hashable. We don't need a valid container.xml — the
        // metadata reader gracefully returns an empty payload.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-test-\(UUID().uuidString).epub")
        try Data("not-a-real-epub-but-hashable".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let book = try store.importBook(from: tmp)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(store.books.first?.id, book.id)

        store.remove(id: book.id)
        XCTAssertTrue(store.books.isEmpty)
    }

    func testImportSameFileTwiceDeduplicates() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-dedup-\(UUID().uuidString).epub")
        try Data("dedup-fixture".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try store.importBook(from: tmp)
        _ = try store.importBook(from: tmp)
        XCTAssertEqual(store.books.count, 1,
                       "importing the same file twice must collapse to a single entry")
    }
}
