import XCTest

@testable import EpubToMp3

extension LibraryStoreTests {
    @MainActor
    func testIndexWorkerDoesNotBlockMainAndPersistsSnapshotsInOrder() async throws {
        let suite = "library.index-worker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = BookEntity(id: "index-book", title: "Initial", bookmark: Data([1]),
                              displayFilename: "Book.epub", addedAt: .now)
        defaults.set(try JSONEncoder().encode([book]), forKey: "library.books.v1")
        let probe = LibraryEncoderProbe()
        let store = LibraryStore(defaults: defaults, indexEncoder: { try probe.encode($0) })
        defer { try? store.flushPersistenceSync() }
        let entered = expectation(description: "index encoding is blocked on its worker")
        probe.pauseNextEncoding(until: entered)
        book.title = "First"
        store.update(book)
        await fulfillment(of: [entered], timeout: 3)
        let heartbeat = expectation(description: "main actor can mutate while encoder is blocked")
        Task { @MainActor in
            XCTAssertTrue(Thread.isMainThread)
            var latest = book
            latest.title = "Latest"
            latest.tags = ["Kept"]
            store.update(latest)
            heartbeat.fulfill()
        }
        await fulfillment(of: [heartbeat], timeout: 2)
        probe.releaseEncoding()
        try await store.flushPersistence()
        XCTAssertEqual(probe.encodedSnapshots.map { $0.0 }, [false, false])
        XCTAssertEqual(probe.encodedSnapshots.map { $0.1 }, ["First", "Latest"])
        let reloaded = LibraryStore(defaults: defaults)
        XCTAssertEqual(reloaded.books.first?.title, "Latest")
        XCTAssertEqual(reloaded.books.first?.tags, ["Kept"])
    }

    @MainActor
    func testIndexEncodingFailurePreservesCommittedIndexAndFlushReportsIt() async throws {
        let suite = "library.index-failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var book = BookEntity(id: "index-book", title: "Committed", bookmark: Data([1]),
                              displayFilename: "Book.epub", addedAt: .now)
        let committed = try JSONEncoder().encode([book])
        defaults.set(committed, forKey: "library.books.v1")
        let store = LibraryStore(defaults: defaults)
        defer { try? store.flushPersistenceSync() }
        book.lastPositionSeconds = .nan
        store.update(book)
        do {
            try await store.flushPersistence()
            XCTFail("Failed encoding must be reported by flush")
        } catch {
            XCTAssertTrue(error is EncodingError)
        }
        XCTAssertEqual(defaults.data(forKey: "library.books.v1"), committed)
        XCTAssertThrowsError(try store.flushPersistenceSync())
        book.lastPositionSeconds = 42
        book.title = "Recovered"
        store.update(book)
        try await store.flushPersistence()
        XCTAssertEqual(LibraryStore(defaults: defaults).books.first?.title, "Recovered")
    }

    func testCompatibilitySyncFlushMakesRemovalVisibleToImmediateReload() throws {
        let (store, defaults, _) = ephemeralStore()
        store.installUITestFixtureIfRequested(arguments: ["-uiTestFixture"])
        store.remove(id: "ui-test-book")
        try store.flushPersistenceSync()
        XCTAssertTrue(LibraryStore(defaults: defaults).books.isEmpty)
    }

    @MainActor
    func testAsyncImportReportsIndexFailureAndPreservesItsSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-index-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "library.index-import.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults, importDirectory: root, indexEncoder: { _ in
            throw NSError(domain: "LibraryPersistenceTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Index encoding failed"])
        })
        defer { try? store.flushPersistenceSync() }
        let source = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: source) }
        let bytes = try Data(contentsOf: source)
        let outcomes = await store.importBooks(from: [source])
        XCTAssertNil(outcomes.first?.book, "Inbox cleanup must not see a successful import before index commit")
        XCTAssertTrue(outcomes.first?.error?.contains("Index encoding failed") == true)
        XCTAssertTrue(store.books.isEmpty, "A failed index commit must not leave an unindexed book visible in memory")
        XCTAssertNil(defaults.data(forKey: "library.books.v1"))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor
    func testFailedImportCommitPreservesConcurrentBookEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-index-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "library.index-race.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = LibraryEncoderProbe()
        probe.failNextEncoding()
        let store = LibraryStore(defaults: defaults, importDirectory: root,
                                 indexEncoder: { try probe.encode($0) })
        defer { try? store.flushPersistenceSync() }
        let source = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: source) }
        let encoding = expectation(description: "import index encoding is blocked before failing")
        probe.pauseNextEncoding(until: encoding)

        let importing = Task { await store.importBooks(from: [source]) }
        await fulfillment(of: [encoding], timeout: 3)
        var edited = try XCTUnwrap(store.books.first)
        edited.title = "Edited while import commit is pending"
        store.update(edited)
        probe.releaseEncoding()

        let outcomes = await importing.value
        XCTAssertNil(outcomes.first?.book)
        XCTAssertTrue(outcomes.first?.error?.contains("Index encoding failed") == true)
        XCTAssertEqual(store.books, [edited])
        try await store.flushPersistence()
        XCTAssertEqual(LibraryStore(defaults: defaults).books, [edited])
    }
}
