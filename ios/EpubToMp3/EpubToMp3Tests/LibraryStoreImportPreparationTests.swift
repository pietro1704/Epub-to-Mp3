import XCTest

@testable import EpubToMp3

extension LibraryStoreTests {
    @MainActor
    func testAsyncBatchPreparesOffMainAndPersistsSuccessfulBooksOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "library.batch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(ObservedLibraryDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ObservedImportFileManager()
        let store = LibraryStore(defaults: defaults, fileManager: manager,
                                 importDirectory: root.appendingPathComponent("library"))
        defer { try? store.flushPersistenceSync() }
        let epub = try EpubFixture.create()
        let pdf = try PdfFixture.createSinglePage(title: "Batch PDF", author: "Batch Author")
        defer { try? FileManager.default.removeItem(at: epub); try? FileManager.default.removeItem(at: pdf) }
        let missing = root.appendingPathComponent("missing.epub")
        let before = defaults.libraryWrites
        let outcomes = await store.importBooks(from: [epub, pdf, epub, missing])
        XCTAssertEqual(outcomes.count, 4)
        XCTAssertEqual(outcomes[0].book?.title, EpubFixture.title)
        XCTAssertEqual(outcomes[1].book?.title, "Batch PDF")
        XCTAssertNotNil(outcomes[1].book?.coverPNG)
        XCTAssertEqual(outcomes[0].book?.id, outcomes[2].book?.id)
        XCTAssertNotNil(outcomes[3].error)
        XCTAssertEqual(store.books.count, 2)
        XCTAssertEqual(manager.copyThreads, [false, false, false])
        XCTAssertEqual(defaults.libraryWrites - before, 1)
        XCTAssertEqual(defaults.libraryWriteThreads, [false])
        let reloaded = LibraryStore(defaults: defaults)
        XCTAssertEqual(Set(reloaded.books.map(\.id)), Set(store.books.map(\.id)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: epub.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdf.path))
    }

    @MainActor
    func testAsyncReimportMergesCurrentMetadataAndDoesNotResurrectRemovedBooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "library.merge.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ObservedImportFileManager()
        let store = LibraryStore(defaults: defaults, fileManager: manager, importDirectory: root)
        defer { try? store.flushPersistenceSync() }
        let source = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try store.importBook(from: source)
        let entered = expectation(description: "background reimport is preparing")
        manager.pauseNextCopy(until: entered)
        let importing = Task { await store.importBooks(from: [source]) }
        await fulfillment(of: [entered], timeout: 3)
        var edited = original
        edited.title = "User title"
        edited.author = "User author"
        edited.tags = ["Keep"]
        edited.lastJobId = "keep-job"
        edited.cachedOffline = true
        edited.lastChapterIndex = 7
        edited.lastPositionSeconds = 42
        edited.coverPNG = Data("User cover".utf8)
        let heartbeat = expectation(description: "main actor remains responsive during blocked copy")
        Task { @MainActor in
            XCTAssertTrue(Thread.isMainThread)
            store.update(edited)
            heartbeat.fulfill()
        }
        await fulfillment(of: [heartbeat], timeout: 2)
        manager.releaseCopy()
        let result = await importing.value
        let merged = try XCTUnwrap(result.first?.book)
        XCTAssertEqual(merged.title, edited.title)
        XCTAssertEqual(merged.author, edited.author)
        XCTAssertEqual(merged.tags, edited.tags)
        XCTAssertEqual(merged.lastJobId, edited.lastJobId)
        XCTAssertEqual(merged.cachedOffline, edited.cachedOffline)
        XCTAssertEqual(merged.lastChapterIndex, edited.lastChapterIndex)
        XCTAssertEqual(merged.lastPositionSeconds, edited.lastPositionSeconds)
        XCTAssertEqual(merged.coverPNG, edited.coverPNG)
        let removing = expectation(description: "second reimport is preparing")
        manager.pauseNextCopy(until: removing)
        let second = Task { await store.importBooks(from: [source]) }
        await fulfillment(of: [removing], timeout: 3)
        store.remove(id: merged.id)
        manager.releaseCopy()
        let cancelled = await second.value
        XCTAssertNil(cancelled.first?.book)
        XCTAssertNotNil(cancelled.first?.error)
        XCTAssertTrue(store.books.isEmpty)
    }

    @MainActor
    func testAsyncFailedReimportPreservesPriorBookBytesAndIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "library.failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ObservedImportFileManager()
        let store = LibraryStore(defaults: defaults, fileManager: manager, importDirectory: root)
        defer { try? store.flushPersistenceSync() }
        let source = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try store.importBook(from: source)
        let prior = store.books
        let durable = root.appendingPathComponent(original.id).appendingPathComponent(source.lastPathComponent)
        let bytes = try Data(contentsOf: durable)
        manager.failNextCopy()
        let outcomes = await store.importBooks(from: [source])
        XCTAssertNotNil(outcomes.first?.error)
        XCTAssertEqual(store.books, prior)
        XCTAssertEqual(try Data(contentsOf: durable), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path), [source.lastPathComponent])
        let selfImport = await store.importBooks(from: [durable])
        XCTAssertNotNil(selfImport.first?.book)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(try Data(contentsOf: durable), bytes)
    }

    @MainActor
    func testAsyncReimportRejectsStagedBytesThatDoNotMatchTheirContentID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-hash-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "library.hash-race.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = MutatingImportCopyFileManager()
        let store = LibraryStore(defaults: defaults, fileManager: manager, importDirectory: root)
        defer { try? store.flushPersistenceSync() }
        let source = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try store.importBook(from: source)
        let previousBooks = store.books
        let sourceBytes = try Data(contentsOf: source)
        let durable = root.appendingPathComponent(original.id).appendingPathComponent(source.lastPathComponent)
        let previousBytes = try Data(contentsOf: durable)
        let previousIndex = try XCTUnwrap(defaults.data(forKey: "library.books.v1"))
        manager.mutateNextCopy(to: Data("different staged contents".utf8))

        let outcome = await store.importBooks(from: [source]).first

        XCTAssertNil(outcome?.book)
        XCTAssertTrue(outcome?.error?.contains("content changed") == true)
        XCTAssertEqual(store.books, previousBooks)
        XCTAssertEqual(try Data(contentsOf: durable), previousBytes)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(defaults.data(forKey: "library.books.v1"), previousIndex)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path),
                       [source.lastPathComponent])
        XCTAssertEqual(LibraryStore(defaults: defaults).books, previousBooks)
    }

#if os(macOS)
    @MainActor
    func testActualMacLibraryImportCallerUsesBackgroundPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-caller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "library.caller.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ObservedImportFileManager()
        let store = LibraryStore(defaults: defaults, fileManager: manager, importDirectory: root)
        defer { try? store.flushPersistenceSync() }
        let source = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: source) }
        let controller = MacLibraryViewController(library: store, bookmarkStore: BookmarkStore(defaults: defaults),
                                                onOpenBook: { _ in }, onDownloadBook: { _ in }, onConvertBook: { _ in })
        let outcomes = await controller.importSelectedBooks(from: [source])
        XCTAssertNotNil(outcomes.first?.book)
        XCTAssertEqual(manager.copyThreads, [false])
        XCTAssertEqual(store.books.count, 1)
    }
#endif
}
