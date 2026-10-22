import XCTest

@testable import EpubToMp3

extension LibraryStoreTests {
    func testStoreStartsEmpty() {
        let (store, _, suite) = ephemeralStore()
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(store.loadError)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testLoadMigratesPersistedLocalizationKeyOutOfAuthor() throws {
        let suite = "library.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = BookEntity(
            id: "bad-author",
            title: "Book",
            author: "reader.loading",
            bookmark: Data([1]),
            displayFilename: "book.epub",
            addedAt: .now
        )
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.books.v1")

        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        defer { try? store.flushPersistenceSync() }
        XCTAssertNil(store.books.first?.author)
    }

    func testUITestFixtureInstallsDeterministicBook() {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.installUITestFixtureIfRequested(arguments: ["-uiTestFixture"])

        XCTAssertEqual(store.books.map(\.id), ["ui-test-book"])
        XCTAssertEqual(store.books.first?.title, "UI Test Book")
    }

    func testDevelopmentSeedBookImportsOnlyWhenRequestedAndDeduplicates() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: seed) }

        XCTAssertFalse(DevelopmentSeedBook.install(into: store, seedURL: seed))
        XCTAssertTrue(
            DevelopmentSeedBook.install(into: store,
                arguments: ["-developmentSeedBook"],
                seedURL: seed
            )
        )
        XCTAssertEqual(store.books.map(\.title), [EpubFixture.title])
        XCTAssertTrue(
            DevelopmentSeedBook.install(into: store,
                arguments: ["-developmentSeedBook"],
                seedURL: seed
            )
        )
        XCTAssertEqual(store.books.count, 1)
    }

    func testContentHashIsStableAcrossInvocations() throws {
        // Write a deterministic file and ensure the SHA-256-based id is
        // identical across invocations — required for the de-dup path.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-test-\(UUID().uuidString).epub")
        let payload = Data(repeating: 0x42, count: 8 * 1024)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let h1 = try LibraryImportFiles.contentHash(of: tmp)
        let h2 = try LibraryImportFiles.contentHash(of: tmp)
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
        XCTAssertNotEqual(try LibraryImportFiles.contentHash(of: a),
                          try LibraryImportFiles.contentHash(of: b))
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
        let unrelatedBookID = "unrelated-\(UUID().uuidString)"
        ReaderProgressStore.save(bookId: book.id, chapterIndex: 2, offsetFraction: 0.6)
        ReaderProgressStore.save(bookId: unrelatedBookID, chapterIndex: 4, offsetFraction: 0.3)
        defer {
            ReaderProgressStore.evict(bookId: book.id)
            ReaderProgressStore.evict(bookId: unrelatedBookID)
        }

        store.remove(id: book.id)
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(ReaderProgressStore.read(bookId: book.id),
                     "Removing a book must not leave resumable state keyed by its content ID")
        XCTAssertNotNil(ReaderProgressStore.read(bookId: unrelatedBookID),
                        "Removal must preserve other books' reader progress")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path),
                      "Removing the library entry must preserve the user's original EPUB")
    }

    @MainActor
    func testAsyncOpenResolvesAnImportedBook() async throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-async-open-\(UUID().uuidString).epub")
        try Data("async-open-fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let book = try store.importBook(from: file)
        let resolved = try await store.openBookFileAsync(id: book.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
        XCTAssertNotNil(store.books.first?.lastOpenedAt)
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
