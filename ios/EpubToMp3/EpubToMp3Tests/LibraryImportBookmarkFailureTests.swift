import XCTest
@testable import EpubToMp3

private final class ImportBookmarkCreatorProbe: @unchecked Sendable {
    enum Behavior { case normal, failure, empty }

    private let lock = NSLock()
    private var behavior = Behavior.normal
    private var filename: String?
    private var observations: [(url: URL, onMainThread: Bool)] = []

    var requests: [(url: URL, onMainThread: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }

    func set(_ behavior: Behavior, forFilename filename: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.behavior = behavior
        self.filename = filename
    }

    func makeBookmark(for url: URL) throws -> Data {
        lock.lock()
        observations.append((url, Thread.isMainThread))
        let selected = filename == nil || filename == url.lastPathComponent ? behavior : .normal
        lock.unlock()
        switch selected {
        case .normal:
            return try LibraryBookmarkAccess.makeBookmark(for: url)
        case .failure:
            throw NSError(domain: "ImportBookmarkCreatorProbe", code: 71)
        case .empty:
            return Data()
        }
    }
}

@MainActor
final class LibraryImportBookmarkFailureTests: XCTestCase {
    func testAsyncBookmarkFailurePreservesCatalogAndSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        fixture.creator.set(.failure)

        let outcomes = await fixture.library.importBooks(from: [source])

        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.url, source)
        XCTAssertNil(outcome.book)
        XCTAssertTrue(outcome.error?.contains(source.lastPathComponent) == true)
        fixture.assertCatalogUnchanged(books: [], index: nil)
        try fixture.assertSourceUnchanged(source)
        let request = try XCTUnwrap(fixture.creator.requests.first)
        XCTAssertEqual(fixture.creator.requests.count, 1)
        XCTAssertFalse(request.onMainThread)
        XCTAssertTrue(request.url.resolvingSymlinksInPath().path.hasPrefix(fixture.libraryDirectory.path + "/"))
        XCTAssertEqual(try Data(contentsOf: request.url), try Data(contentsOf: source))
    }

    func testSyncBookmarkFailureRetainsUnderlyingCauseAndDoesNotPublish() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        fixture.creator.set(.failure)

        XCTAssertThrowsError(try fixture.library.importBook(from: source)) { error in
            let failure = error as NSError
            XCTAssertEqual(failure.domain, "LibraryStore")
            XCTAssertEqual(failure.code, 3)
            let cause = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(cause?.domain, "ImportBookmarkCreatorProbe")
            XCTAssertEqual(cause?.code, 71)
        }

        fixture.assertCatalogUnchanged(books: [], index: nil)
        try fixture.assertSourceUnchanged(source)
    }

    func testEmptyBookmarkIsRejectedBeforePublishingCatalog() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        fixture.creator.set(.empty)

        let outcomes = await fixture.library.importBooks(from: [source])

        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertNil(outcome.book)
        XCTAssertNotNil(outcome.error)
        fixture.assertCatalogUnchanged(books: [], index: nil)
        try fixture.assertSourceUnchanged(source)
    }

    func testFailedReimportPreservesExistingMetadataIndexAndBothBookFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let otherSource = try fixture.makeSource(format: .pdf)
        var existing = try await fixture.library.importBookAsync(from: source)
        let other = try await fixture.library.importBookAsync(from: otherSource)
        existing.title = "Listener title"
        existing.lastJobId = "retained-job"
        existing.lastChapterIndex = 4
        existing.lastPositionSeconds = 27
        fixture.library.update(existing)
        try await fixture.library.flushPersistence()
        let books = fixture.library.books
        let index = try XCTUnwrap(fixture.defaults.data(forKey: "library.books.v1"))
        fixture.creator.set(.failure, forFilename: source.lastPathComponent)

        let outcomes = await fixture.library.importBooks(from: [source])

        XCTAssertNil(outcomes.first?.book)
        XCTAssertNotNil(outcomes.first?.error)
        fixture.assertCatalogUnchanged(books: books, index: index)
        try fixture.assertDurableBook(id: existing.id, from: source)
        try fixture.assertDurableBook(id: other.id, from: otherSource)
        try fixture.assertSourceUnchanged(source)
        try fixture.assertSourceUnchanged(otherSource)
    }

    func testAsyncInboxBookmarkFailureKeepsSourceUntilSuccessfulRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let unrelated = try fixture.makeSource(format: .pdf)
        fixture.creator.set(.failure)

        let failed = await SharedContainerImporter.drainAsync(urls: [source], into: fixture.library)

        XCTAssertNil(failed.first?.importedBookID)
        XCTAssertNotNil(failed.first?.error)
        fixture.assertCatalogUnchanged(books: [], index: nil)
        try fixture.assertSourceUnchanged(source)
        try fixture.assertSourceUnchanged(unrelated)
        fixture.creator.set(.normal)

        let retried = await SharedContainerImporter.drainAsync(urls: [source], into: fixture.library)

        let bookID = try XCTUnwrap(retried.first?.importedBookID)
        XCTAssertNil(retried.first?.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(fixture.library.books.map(\.id), [bookID])
        try fixture.assertDurableBook(id: bookID, from: source)
        try fixture.assertSourceUnchanged(unrelated)
    }

    func testSyncInboxBookmarkFailureDoesNotDeleteSource() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        fixture.creator.set(.failure)

        let outcomes = SharedContainerImporter.drain(urls: [source], into: fixture.library)

        XCTAssertNil(outcomes.first?.importedBookID)
        XCTAssertNotNil(outcomes.first?.error)
        fixture.assertCatalogUnchanged(books: [], index: nil)
        try fixture.assertSourceUnchanged(source)
    }

    func testDocumentsBookmarkFailureAllowsRetryWithoutChangingSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        fixture.creator.set(.failure)

        let failed = await DocumentsBookImporter.importPendingAsync(
            in: fixture.sourceDirectory, into: fixture.library, defaults: fixture.defaults)

        XCTAssertEqual(failed.count, 1)
        XCTAssertNil(failed.first?.importedBookID)
        XCTAssertNotNil(failed.first?.error)
        fixture.assertCatalogUnchanged(books: [], index: nil)
        try fixture.assertSourceUnchanged(source)
        fixture.creator.set(.normal)

        let retried = await DocumentsBookImporter.importPendingAsync(
            in: fixture.sourceDirectory, into: fixture.library, defaults: fixture.defaults)
        let bookID = try XCTUnwrap(retried.first?.importedBookID)
        XCTAssertEqual(retried.count, 1)
        XCTAssertNil(retried.first?.error)
        try fixture.assertSourceUnchanged(source)
        try fixture.assertDurableBook(id: bookID, from: source)
        let repeated = await DocumentsBookImporter.importPendingAsync(
            in: fixture.sourceDirectory, into: fixture.library, defaults: fixture.defaults)
        XCTAssertTrue(repeated.isEmpty, "Only a successful import may mark unchanged Documents content as processed")
    }

    func testMixedBatchPublishesOnlyBookWithUsableBookmark() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let failedSource = try fixture.makeSource()
        let successfulSource = try fixture.makeSource(format: .pdf)
        fixture.creator.set(.failure, forFilename: failedSource.lastPathComponent)

        let outcomes = await fixture.library.importBooks(from: [failedSource, successfulSource])

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes[0].url, failedSource)
        XCTAssertNil(outcomes[0].book)
        XCTAssertNotNil(outcomes[0].error)
        XCTAssertEqual(outcomes[1].url, successfulSource)
        let imported = try XCTUnwrap(outcomes[1].book)
        XCTAssertNil(outcomes[1].error)
        XCTAssertEqual(imported.fileType, .pdf)
        XCTAssertFalse(imported.bookmark.isEmpty)
        XCTAssertEqual(fixture.library.books.map(\.id), [imported.id])
        XCTAssertEqual(fixture.reloadedLibrary().books.map(\.id), [imported.id])
        XCTAssertEqual(fixture.creator.requests.count, 2)
        XCTAssertTrue(fixture.creator.requests.allSatisfy { !$0.onMainThread })
        try fixture.assertDurableBook(id: imported.id, from: successfulSource)
        try fixture.assertSourceUnchanged(failedSource)
        try fixture.assertSourceUnchanged(successfulSource)
    }

    func testCancelledInboxImportDoesNotPublishOrDeleteSource() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let source = try fixture.makeSource()
        let copying = expectation(description: "Inbox copy is suspended")
        fixture.files.pauseNextCopy(until: copying)
        defer { fixture.files.releaseCopy() }
        let task = Task { await SharedContainerImporter.drainAsync(urls: [source], into: fixture.library) }
        await fulfillment(of: [copying], timeout: 3)

        task.cancel()
        fixture.files.releaseCopy()
        let outcomes = await task.value

        XCTAssertNil(outcomes.first?.importedBookID)
        XCTAssertNotNil(outcomes.first?.error)
        fixture.assertCatalogUnchanged(books: [], index: nil)
        try fixture.assertSourceUnchanged(source)
    }

    @MainActor
    private final class Fixture {
        let suite = "library-import-bookmark-\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let sourceDirectory: URL
        let libraryDirectory: URL
        let files = ObservedImportFileManager()
        let creator = ImportBookmarkCreatorProbe()
        let library: LibraryStore
        private var sourceContents: [URL: Data] = [:]

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
            sourceDirectory = root.appendingPathComponent("sources")
            libraryDirectory = root.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let bookmarkCreator = creator
            library = LibraryStore(defaults: defaults, fileManager: files, importDirectory: libraryDirectory,
                                   importBookmarkCreator: { try bookmarkCreator.makeBookmark(for: $0) })
        }

        func makeSource(format: BookFileType = .epub) throws -> URL {
            let generated: URL
            if format == .pdf {
                generated = try PdfFixture.createSinglePage()
            } else {
                generated = try EpubFixture.createWithChapter(body: "Imported book with a durable bookmark.")
            }
            defer { try? FileManager.default.removeItem(at: generated) }
            let source = sourceDirectory.appendingPathComponent(generated.lastPathComponent)
            try FileManager.default.moveItem(at: generated, to: source)
            sourceContents[source] = try Data(contentsOf: source)
            return source
        }

        func reloadedLibrary() -> LibraryStore {
            LibraryStore(defaults: defaults, importDirectory: libraryDirectory)
        }

        func assertCatalogUnchanged(books: [BookEntity], index: Data?, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(library.books, books, file: file, line: line)
            XCTAssertEqual(defaults.data(forKey: "library.books.v1"), index, file: file, line: line)
            XCTAssertEqual(reloadedLibrary().books, books, file: file, line: line)
        }

        func assertSourceUnchanged(_ source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
            let original = try XCTUnwrap(sourceContents[source], file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: source), original, file: file, line: line)
        }

        func assertDurableBook(id: String, from source: URL, file: StaticString = #filePath, line: UInt = #line) throws {
            let book = try XCTUnwrap(reloadedLibrary().books.first { $0.id == id }, file: file, line: line)
            XCTAssertFalse(book.bookmark.isEmpty, file: file, line: line)
            let copy = try LibraryBookmarkAccess.resolveBookBookmark(book.bookmark).url.resolvingSymlinksInPath()
            XCTAssertTrue(copy.path.hasPrefix(libraryDirectory.path + "/"), file: file, line: line)
            let original = try XCTUnwrap(sourceContents[source], file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: copy), original, file: file, line: line)
        }

        func cleanUp() {
            try? library.flushPersistenceSync()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
