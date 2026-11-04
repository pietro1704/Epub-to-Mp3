import Foundation
import XCTest
@testable import EpubToMp3

@MainActor
final class LibraryCatalogRecoverySafetyTests: XCTestCase {
    private let undecodableIndexes = [Data("{invalid library".utf8), Data("{\"futureCatalog\":[]}".utf8)]

    func testFailedCatalogRejectsSyncImportWithoutChangingIndexOrSource() throws {
        for originalIndex in undecodableIndexes {
            let fixture = try CatalogRecoveryFixture(indexData: originalIndex)
            defer { fixture.cleanup() }
            let source = try fixture.writeSource(named: "Picked.epub")
            let originalSource = try Data(contentsOf: source)

            XCTAssertNotNil(fixture.library.loadError)
            XCTAssertThrowsError(try fixture.library.importBook(from: source))

            XCTAssertTrue(fixture.library.books.isEmpty)
            XCTAssertEqual(fixture.defaults.data(forKey: "library"), originalIndex)
            XCTAssertEqual(try Data(contentsOf: source), originalSource)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.importDirectory.path),
                           "An unreadable catalog must fail before preparing an unindexable copy")
            let reloaded = LibraryStore(defaults: fixture.defaults, defaultsKey: "library",
                                        importDirectory: fixture.importDirectory)
            XCTAssertNotNil(reloaded.loadError)
        }
    }

    func testFailedCatalogRejectsAsyncInboxImportsAndPreservesEverySource() async throws {
        let originalIndex = undecodableIndexes[0]
        let fixture = try CatalogRecoveryFixture(indexData: originalIndex)
        defer { fixture.cleanup() }
        let sources = try ["First.epub", "Second.epub"].map { try fixture.writeSource(named: $0) }
        let originalSources = try sources.map { try Data(contentsOf: $0) }

        let outcomes = await SharedContainerImporter.drainAsync(urls: sources, into: fixture.library)

        XCTAssertEqual(outcomes.map(\.url), sources)
        XCTAssertTrue(outcomes.allSatisfy { $0.importedBookID == nil && $0.error != nil })
        XCTAssertTrue(fixture.library.books.isEmpty)
        XCTAssertEqual(fixture.defaults.data(forKey: "library"), originalIndex)
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, originalSources)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.importDirectory.path))
    }

    func testFailedCatalogRejectsSyncInboxCleanup() throws {
        let originalIndex = undecodableIndexes[0]
        let fixture = try CatalogRecoveryFixture(indexData: originalIndex)
        defer { fixture.cleanup() }
        let source = try fixture.writeSource(named: "Shared.epub")
        let originalSource = try Data(contentsOf: source)

        let outcomes = SharedContainerImporter.drain(urls: [source], into: fixture.library)

        XCTAssertNil(outcomes.first?.importedBookID)
        XCTAssertNotNil(outcomes.first?.error)
        XCTAssertEqual(try Data(contentsOf: source), originalSource)
        XCTAssertEqual(fixture.defaults.data(forKey: "library"), originalIndex)
    }

    func testFailedCatalogFlushReportsUnavailableInsteadOfSuccessfulCommit() async throws {
        let originalIndex = undecodableIndexes[0]
        let fixture = try CatalogRecoveryFixture(indexData: originalIndex)
        defer { fixture.cleanup() }

        XCTAssertThrowsError(try fixture.library.flushPersistenceSync())
        do {
            try await fixture.library.flushPersistence()
            XCTFail("Flushing a catalog that never decoded must not report a successful commit")
        } catch {
            XCTAssertEqual((error as NSError).domain, "LibraryStore")
        }
        XCTAssertEqual(fixture.defaults.data(forKey: "library"), originalIndex)
    }

    func testFailedCatalogDoesNotPrunePersistedBookmarksFulltextOrRecency() throws {
        for originalIndex in undecodableIndexes {
            let fixture = try CatalogRecoveryFixture(indexData: originalIndex)
            defer { fixture.cleanup() }
            let bookID = "retained" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let bookmarks = try fixture.seedMaintenance(bookIDs: [bookID])
            let bookmarkBytes = try XCTUnwrap(fixture.defaults.data(forKey: "bookmarks"))
            let payloadURL = fixture.fulltextDirectory.appendingPathComponent(bookID + ".plist")
            let payloadBytes = try Data(contentsOf: payloadURL)

            fixture.pruneLibraryOrphans(bookmarks: bookmarks)

            XCTAssertEqual(bookmarks.bookmarks.count, 1)
            XCTAssertEqual(fixture.defaults.data(forKey: "bookmarks"), bookmarkBytes)
            XCTAssertEqual(BookmarkStore(defaults: fixture.defaults, storageKey: "bookmarks").bookmarks.count, 1)
            XCTAssertEqual(try Data(contentsOf: payloadURL), payloadBytes)
            XCTAssertEqual(fixture.defaults.stringArray(forKey: "readerWarmBookIDs.v1"), [bookID])
            XCTAssertEqual(fixture.defaults.data(forKey: "library"), originalIndex)
            try fixture.assertRetainedAudio()
        }
    }

    func testLoadedCatalogPrunesOnlyActualOrphans() throws {
        let retainedID = "retained" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let orphanID = "orphan" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let book = BookEntity(id: retainedID, title: "Retained", bookmark: Data([1]),
                              displayFilename: "Retained.epub", addedAt: .distantPast)
        let fixture = try CatalogRecoveryFixture(indexData: JSONEncoder().encode([book]))
        defer { fixture.cleanup() }
        let bookmarks = try fixture.seedMaintenance(bookIDs: [retainedID, orphanID])
        let retained = fixture.fulltextDirectory.appendingPathComponent(retainedID + ".plist")
        let originalPayload = try Data(contentsOf: retained)

        fixture.pruneLibraryOrphans(bookmarks: bookmarks)

        XCTAssertEqual(bookmarks.bookmarks.map(\.bookId), [retainedID])
        XCTAssertEqual(try Data(contentsOf: retained), originalPayload)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.fulltextDirectory.appendingPathComponent(orphanID + ".plist").path))
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "readerWarmBookIDs.v1"), [retainedID])
        try fixture.assertRetainedAudio()
    }

    func testMissingAndValidEmptyCatalogsStillPermitOrphanMaintenance() throws {
        for initialIndex in [nil, Data("[]".utf8)] as [Data?] {
            let fixture = try CatalogRecoveryFixture(indexData: initialIndex)
            defer { fixture.cleanup() }
            let orphanID = "orphan" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let bookmarks = try fixture.seedMaintenance(bookIDs: [orphanID])

            fixture.pruneLibraryOrphans(bookmarks: bookmarks)

            XCTAssertNil(fixture.library.loadError)
            XCTAssertTrue(bookmarks.bookmarks.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.fulltextDirectory.appendingPathComponent(orphanID + ".plist").path))
            XCTAssertEqual(fixture.defaults.stringArray(forKey: "readerWarmBookIDs.v1"), [])
            try fixture.assertRetainedAudio()
        }
    }

    func testMissingAndValidEmptyCatalogsStillImportAndReload() async throws {
        for initialIndex in [nil, Data("[]".utf8)] as [Data?] {
            let fixture = try CatalogRecoveryFixture(indexData: initialIndex)
            defer { fixture.cleanup() }
            let source = try fixture.writeSource(named: "New.epub")
            let originalSource = try Data(contentsOf: source)

            let imported = try await fixture.library.importBookAsync(from: source)

            let reloaded = LibraryStore(defaults: fixture.defaults, defaultsKey: "library",
                                        importDirectory: fixture.importDirectory)
            XCTAssertNil(reloaded.loadError)
            XCTAssertEqual(reloaded.books.map(\.id), [imported.id])
            XCTAssertFalse(imported.bookmark.isEmpty)
            XCTAssertEqual(try Data(contentsOf: source), originalSource)
        }
    }

    func testCancelledImportIntoFreshCatalogDoesNotPublishOrCreateCopies() async throws {
        let fixture = try CatalogRecoveryFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeSource(named: "Cancelled.epub")
        let originalSource = try Data(contentsOf: source)
        let importing = Task { @MainActor in await fixture.library.importBooks(from: [source]) }
        importing.cancel()

        let outcomes = await importing.value

        XCTAssertNil(outcomes.first?.book)
        XCTAssertNotNil(outcomes.first?.error)
        XCTAssertTrue(fixture.library.books.isEmpty)
        XCTAssertNil(fixture.defaults.data(forKey: "library"))
        XCTAssertEqual(try Data(contentsOf: source), originalSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.importDirectory.path))
    }
}

@MainActor
private final class CatalogRecoveryFixture {
    let suite = "library.catalog-recovery.\(UUID().uuidString)"
    let root: URL
    let defaults: UserDefaults
    let library: LibraryStore
    var importDirectory: URL { root.appendingPathComponent("library") }
    var fulltextDirectory: URL { root.appendingPathComponent("fulltext") }

    init(indexData: Data? = nil) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = temporary.resolvingSymlinksInPath()
        if let indexData { defaults.set(indexData, forKey: "library") }
        library = LibraryStore(defaults: defaults, defaultsKey: "library",
                               importDirectory: root.appendingPathComponent("library"))
    }

    func writeSource(named filename: String) throws -> URL {
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let source = inbox.appendingPathComponent(filename)
        // Metadata is optional for EPUB import; this fixture only exercises storage.
        try Data("Unchanged source bytes for \(filename)".utf8).write(to: source)
        return source
    }

    func seedMaintenance(bookIDs: [String]) throws -> BookmarkStore {
        let bookmarks = BookmarkStore(defaults: defaults, storageKey: "bookmarks")
        try FileManager.default.createDirectory(at: fulltextDirectory, withIntermediateDirectories: true)
        for id in bookIDs {
            bookmarks.addBookmark(bookId: id, chapterIndex: 0, chapterTitle: "Retained chapter")
            try Data("Retained prepared text for \(id)".utf8)
                .write(to: fulltextDirectory.appendingPathComponent(id + ".plist"))
        }
        defaults.set(bookIDs, forKey: "readerWarmBookIDs.v1")
        try Data("Retained offline audio".utf8).write(to: fulltextDirectory.appendingPathComponent("retained.mp3"))
        return bookmarks
    }

    func pruneLibraryOrphans(bookmarks: BookmarkStore) {
        // Invoke the application's real maintenance seam directly, so its
        // XCTest-host activation guard cannot hide an unsafe prune.
        EpubToMp3App.pruneLibraryOrphans(library: library, bookmarkStore: bookmarks) { validIDs in
            LocalFulltextCache.pruneOrphans(validBookIds: validIDs, directory: fulltextDirectory, defaults: defaults)
        }
    }

    func assertRetainedAudio(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fulltextDirectory.appendingPathComponent("retained.mp3")),
                       Data("Retained offline audio".utf8), file: file, line: line)
    }

    func cleanup() {
        try? library.flushPersistenceSync()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
