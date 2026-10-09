import XCTest
@testable import EpubToMp3

private final class FailingImportCopyFileManager: FileManager, @unchecked Sendable {
    var failReplacement = false

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if failReplacement {
            try super.copyItem(at: srcURL, to: dstURL)
            return
        }
        try Data("Partial copy".utf8).write(to: dstURL)
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    }

    override func replaceItem(at originalItemURL: URL, withItemAt newItemURL: URL,
                             backupItemName: String?, options: ItemReplacementOptions,
                             resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
    }
}

private final class MutatingImportCopyFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var nextCopyContents: Data?

    func mutateNextCopy(to contents: Data) {
        lock.lock(); defer { lock.unlock() }
        nextCopyContents = contents
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        lock.lock()
        let replacement = nextCopyContents
        nextCopyContents = nil
        lock.unlock()
        if let replacement { try replacement.write(to: dstURL, options: .atomic) }
    }
}

/// Only the test manager crosses threads; mutable observations are lock-protected.
private final class ObservedImportFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var pause: XCTestExpectation?
    private var failCopy = false
    private var observations: [Bool] = []

    func pauseNextCopy(until expectation: XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        pause = expectation
    }

    func releaseCopy() { release.signal() }

    func failNextCopy() {
        lock.lock(); defer { lock.unlock() }
        failCopy = true
    }

    var copyThreads: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        lock.lock()
        observations.append(Thread.isMainThread)
        let waiting = pause
        pause = nil
        let failing = failCopy
        failCopy = false
        lock.unlock()
        if let waiting {
            waiting.fulfill()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw NSError(domain: "LibraryImportTests", code: 1)
            }
        }
        if failing {
            try Data("Partial copy".utf8).write(to: destination)
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        }
        try super.copyItem(at: source, to: destination)
    }
}

private final class ObservedLibraryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var writeThreads: [Bool] = []
    var libraryWrites: Int {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
    var libraryWriteThreads: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return writeThreads
    }
    override func set(_ value: Any?, forKey key: String) {
        if key == "library.books.v1" {
            lock.lock(); writes += 1; writeThreads.append(Thread.isMainThread); lock.unlock()
        }
        super.set(value, forKey: key)
    }
}

private final class LibraryEncoderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var waiting: XCTestExpectation?
    private var failNext = false
    private var observations: [(Bool, String?)] = []

    func pauseNextEncoding(until expectation: XCTestExpectation) {
        lock.lock(); defer { lock.unlock() }
        waiting = expectation
    }
    func releaseEncoding() { resume.signal() }
    func failNextEncoding() {
        lock.lock(); defer { lock.unlock() }
        failNext = true
    }
    var encodedSnapshots: [(Bool, String?)] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }
    func encode(_ books: [BookEntity]) throws -> Data {
        lock.lock()
        observations.append((Thread.isMainThread, books.first?.title))
        let entered = waiting
        waiting = nil
        let shouldFail = failNext
        failNext = false
        lock.unlock()
        if let entered {
            entered.fulfill()
            guard resume.wait(timeout: .now() + 5) == .success else {
                throw NSError(domain: "LibraryPersistenceTests", code: 1)
            }
        }
        if shouldFail {
            throw NSError(domain: "LibraryPersistenceTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Index encoding failed"])
        }
        return try JSONEncoder().encode(books)
    }
}

final class LibraryStoreTests: XCTestCase {

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

    private func ephemeralStore() -> (LibraryStore, UserDefaults, String) {
        let suite = "library.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        addTeardownBlock {
            try? store.flushPersistenceSync()
            defaults.removePersistentDomain(forName: suite)
        }
        return (store, defaults, suite)
    }

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

        XCTAssertFalse(store.installDevelopmentSeedBookIfRequested(seedURL: seed))
        XCTAssertTrue(
            store.installDevelopmentSeedBookIfRequested(
                arguments: ["-developmentSeedBook"],
                seedURL: seed
            )
        )
        XCTAssertEqual(store.books.map(\.title), [EpubFixture.title])
        XCTAssertTrue(
            store.installDevelopmentSeedBookIfRequested(
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
        ReaderProgressStore.save(bookId: book.id, chapterIndex: 2, offsetFraction: 0.6, defaults: defaults)
        ReaderProgressStore.save(bookId: "unrelated-book", chapterIndex: 4, offsetFraction: 0.3, defaults: defaults)

        store.remove(id: book.id)
        XCTAssertTrue(store.books.isEmpty)
        XCTAssertNil(ReaderProgressStore.read(bookId: book.id, defaults: defaults),
                     "Removing a book must not leave resumable state keyed by its content ID")
        XCTAssertNotNil(ReaderProgressStore.read(bookId: "unrelated-book", defaults: defaults),
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

    func testImportPdfStoresFileTypeAndMetadata() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let pdf = try PdfFixture.createSinglePage(
            title: "Imported PDF",
            author: "PDF Author",
            bodyText: "Body text."
        )
        defer { try? FileManager.default.removeItem(at: pdf) }

        let book = try store.importBook(from: pdf)
        XCTAssertEqual(book.fileType, .pdf)
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(book.title, "Imported PDF")
        XCTAssertEqual(book.author, "PDF Author")
        // PDFKit should have produced a cover thumbnail.
        XCTAssertNotNil(book.coverPNG)
    }

    func testImportRejectsUnsupportedExtensionInsteadOfSilentlyTreatingAsEpub() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-book-\(UUID().uuidString).txt")
        try Data("plain text file".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        XCTAssertThrowsError(try store.importBook(from: tmp)) { error in
            XCTAssertTrue((error as NSError).localizedDescription.contains(tmp.lastPathComponent))
        }
        XCTAssertTrue(store.books.isEmpty)
    }

    func testImportAcceptsFb2AndCbzExtensions() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let fb2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("book-\(UUID().uuidString).fb2")
        try Data("<FictionBook/>".utf8).write(to: fb2)
        let cbz = FileManager.default.temporaryDirectory
            .appendingPathComponent("comic-\(UUID().uuidString).cbz")
        try Data("pk-not-really-a-zip".utf8).write(to: cbz)
        defer {
            try? FileManager.default.removeItem(at: fb2)
            try? FileManager.default.removeItem(at: cbz)
        }

        let fb2Book = try store.importBook(from: fb2)
        let cbzBook = try store.importBook(from: cbz)
        XCTAssertEqual(fb2Book.fileType, .fb2)
        XCTAssertEqual(cbzBook.fileType, .cbz)
        XCTAssertEqual(store.books.count, 2)
    }

    func testLibraryAcceptsBothEpubAndPdfInSameSession() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let epub = try EpubFixture.create()
        let pdf = try PdfFixture.createSinglePage()
        defer {
            try? FileManager.default.removeItem(at: epub)
            try? FileManager.default.removeItem(at: pdf)
        }

        let epubBook = try store.importBook(from: epub)
        let pdfBook = try store.importBook(from: pdf)
        XCTAssertEqual(epubBook.fileType, .epub)
        XCTAssertEqual(pdfBook.fileType, .pdf)
        XCTAssertEqual(store.books.count, 2)
    }

    func testBookEntityDecodingFallsBackToEpubForLegacyPersistedRow() throws {
        // Simulate a row persisted by a pre-PDF-support build: every
        // current field is there, but `fileType` is missing. The
        // decoder should default to `.epub` so the library doesn't
        // crash on first launch after the upgrade.
        let legacyJSON = """
        {
            "id": "legacy-id",
            "title": "Legacy Book",
            "bookmark": "",
            "displayFilename": "legacy.epub",
            "addedAt": 0,
            "cachedOffline": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BookEntity.self, from: legacyJSON)
        XCTAssertEqual(decoded.fileType, .epub)
    }

    func testBookEntityDecodingDetectsPdfFromLegacyFilenameWhenFileTypeMissing() throws {
        let legacyJSON = """
        {
            "id": "legacy-pdf-id",
            "title": "Legacy PDF",
            "bookmark": "",
            "displayFilename": "legacy.pdf",
            "addedAt": 0,
            "cachedOffline": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BookEntity.self, from: legacyJSON)
        XCTAssertEqual(decoded.fileType, .pdf,
                       "legacy entries with a .pdf displayFilename should infer fileType=.pdf")
    }

    func testDurableImportCopySurvivesOriginalRemoval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-durable-root-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-picked-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("Picked Book.epub")
        try Data("durable import payload".utf8).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceDir)
        }

        let durable = try LibraryStore.persistImportedFileForLibrary(
            originalURL: source,
            id: "abc123",
            fileType: .epub,
            baseDirectory: root
        )
        try FileManager.default.removeItem(at: source)

        XCTAssertTrue(FileManager.default.fileExists(atPath: durable.path))
        XCTAssertEqual(try Data(contentsOf: durable), Data("durable import payload".utf8))
        XCTAssertTrue(durable.path.hasPrefix(root.path))
        XCTAssertEqual(durable.lastPathComponent, "Picked Book.epub")
    }

    func testFailedDurableReplacementPreservesPreviousFile() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let picked = root.appendingPathComponent("picked", isDirectory: true)
        try manager.createDirectory(at: picked, withIntermediateDirectories: true)
        let source = picked.appendingPathComponent("Book.epub")
        let previous = Data("Previous valid book".utf8)
        try previous.write(to: source)
        let storage = root.appendingPathComponent("library", isDirectory: true)
        let durable = try LibraryStore.persistImportedFileForLibrary(
            originalURL: source, id: "replacement", fileType: .epub, baseDirectory: storage
        )
        let replacement = Data("Replacement book".utf8)
        try replacement.write(to: source)

        for failReplacement in [false, true] {
            let failingManager = FailingImportCopyFileManager()
            failingManager.failReplacement = failReplacement
            XCTAssertThrowsError(try LibraryStore.persistImportedFileForLibrary(
                originalURL: source, id: "replacement", fileType: .epub,
                fileManager: failingManager, baseDirectory: storage
            ))
            XCTAssertEqual(try Data(contentsOf: durable), previous)
            XCTAssertEqual(try Data(contentsOf: source), replacement)
            XCTAssertEqual(try manager.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path), ["Book.epub"])
        }
    }

    func testDurableSelfReimportPreservesTheImportedFile() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-self-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Book.epub")
        let contents = Data("Valid imported book".utf8)
        try contents.write(to: source)
        let storage = root.appendingPathComponent("library", isDirectory: true)
        let durable = try LibraryStore.persistImportedFileForLibrary(
            originalURL: source, id: "self-import", fileType: .epub, baseDirectory: storage
        )
        let reimported = try LibraryStore.persistImportedFileForLibrary(
            originalURL: durable, id: "self-import", fileType: .epub, baseDirectory: storage
        )
        XCTAssertEqual(reimported, durable)
        XCTAssertEqual(try Data(contentsOf: durable), contents)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path), ["Book.epub"])
    }

    func testSuccessfulDurableReplacementPreservesBookmarkDestination() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("library-successful-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Book.epub")
        try Data("Previous book".utf8).write(to: source)
        let storage = root.appendingPathComponent("library", isDirectory: true)
        let durable = try LibraryStore.persistImportedFileForLibrary(
            originalURL: source, id: "replacement", fileType: .epub, baseDirectory: storage
        )
        let bookmark = try durable.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let replacement = Data("New complete book".utf8)
        try replacement.write(to: source)
        let replaced = try LibraryStore.persistImportedFileForLibrary(
            originalURL: source, id: "replacement", fileType: .epub, baseDirectory: storage
        )
        XCTAssertEqual(replaced, durable)
        XCTAssertEqual(try Data(contentsOf: durable), replacement)
        XCTAssertEqual(try Data(contentsOf: source), replacement)
        var stale = false
        let resolved = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.standardizedFileURL.path, durable.standardizedFileURL.path)
        XCTAssertEqual(try Data(contentsOf: resolved), replacement)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: durable.deletingLastPathComponent().path), ["Book.epub"])
    }

    #if os(macOS)
    func testMacOSImportUsesAnAppOwnedCopyForFutureAccess() throws {
        let (store, defaults, suite) = ephemeralStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-library-import-\(UUID().uuidString).epub")
        let payload = Data("macOS durable library payload".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let book = try store.importBook(from: source)
        let resolved = try store.openBookFile(id: book.id).standardizedFileURL
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL
            .path

        XCTAssertTrue(
            resolved.path.hasPrefix(applicationSupport + "/EpubToMp3/ImportedBooks/"),
            "macOS library access must resolve to an app-owned copy instead of the picked Documents/external URL"
        )
        XCTAssertNotEqual(resolved, source.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: resolved), payload)
    }
    #endif
}
