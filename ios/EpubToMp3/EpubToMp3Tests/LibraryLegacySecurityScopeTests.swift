#if os(macOS)
import XCTest
@testable import EpubToMp3

private final class LegacyScopeProbe: @unchecked Sendable {
    enum Event: Equatable {
        case start(URL)
        case copy(URL)
        case stop(URL)
    }

    private let lock = NSLock()
    private let grantsAccess: Bool
    private var observations: [Event] = []

    init(grantsAccess: Bool) { self.grantsAccess = grantsAccess }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return observations
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        observations.removeAll()
    }

    func start(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        observations.append(.start(url.resolvingSymlinksInPath()))
        return grantsAccess
    }

    func copying(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        observations.append(.copy(url.resolvingSymlinksInPath()))
    }

    func stop(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        observations.append(.stop(url.resolvingSymlinksInPath()))
    }
}

private final class LegacyScopeFileManager: FileManager, @unchecked Sendable {
    private let scope: LegacyScopeProbe
    private let failsCopy: Bool

    init(scope: LegacyScopeProbe, failsCopy: Bool) {
        self.scope = scope
        self.failsCopy = failsCopy
        super.init()
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        scope.copying(source)
        if failsCopy { throw CocoaError(.fileReadNoPermission) }
        try super.copyItem(at: source, to: destination)
    }
}

final class LibraryLegacySecurityScopeTests: XCTestCase {
    func testSuccessfulMigrationClosesOriginalScopeBeforeReturningDurableURL() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        let opened = try fixture.open()

        XCTAssertEqual(fixture.scope.events, [.start(fixture.source), .copy(fixture.source), .stop(fixture.source)])
        XCTAssertNotEqual(opened.resolvingSymlinksInPath(), fixture.source)
        XCTAssertTrue(opened.resolvingSymlinksInPath().path.hasPrefix(fixture.libraryDirectory.path + "/"))
        XCTAssertEqual(try Data(contentsOf: opened), fixture.sourceBytes)
        try fixture.library.flushPersistenceSync()
        let reloaded = fixture.reloadedLibrary()
        let migrated = try XCTUnwrap(reloaded.books.first { $0.id == fixture.book.id })
        XCTAssertNotEqual(migrated.bookmark, fixture.book.bookmark)
        XCTAssertNotNil(migrated.lastOpenedAt)
        let bookmarkURL = try LibraryBookmarkAccess.resolveBookBookmark(migrated.bookmark).url
        XCTAssertEqual(bookmarkURL.resolvingSymlinksInPath(), opened.resolvingSymlinksInPath())
        try fixture.assertSourcesAndUnrelatedBookUnchanged()
    }

    func testFailedMigrationClosesOriginalScopeAndPreservesCatalogAndExistingCopy() throws {
        let fixture = try Fixture(failsCopy: true)
        defer { fixture.cleanUp() }
        let existing = fixture.libraryDirectory.appendingPathComponent(fixture.book.id)
            .appendingPathComponent(fixture.source.lastPathComponent)
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = Data("Existing durable content must survive failed migration.".utf8)
        try previous.write(to: existing)

        XCTAssertThrowsError(try fixture.open()) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileReadNoPermission.rawValue)
        }

        XCTAssertEqual(fixture.scope.events, [.start(fixture.source), .copy(fixture.source), .stop(fixture.source)])
        XCTAssertEqual(fixture.library.books, [fixture.book, fixture.otherBook])
        XCTAssertEqual(fixture.defaults.data(forKey: "library"), fixture.initialIndex)
        XCTAssertEqual(fixture.reloadedLibrary().books, [fixture.book, fixture.otherBook])
        XCTAssertEqual(try Data(contentsOf: existing), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existing.deletingLastPathComponent().path),
                       [existing.lastPathComponent])
        try fixture.assertSourcesAndUnrelatedBookUnchanged()
    }

    func testUnstartedScopeIsNeverStoppedWhenMigrationStillSucceeds() throws {
        let fixture = try Fixture(grantsAccess: false)
        defer { fixture.cleanUp() }

        let opened = try fixture.open()

        XCTAssertEqual(fixture.scope.events, [.start(fixture.source), .copy(fixture.source)])
        XCTAssertEqual(try Data(contentsOf: opened), fixture.sourceBytes)
        try fixture.assertSourcesAndUnrelatedBookUnchanged()
    }

    func testAlreadyOwnedBookDoesNotStartCopyOrStopExternalScope() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let migrated = try fixture.open()
        fixture.scope.reset()

        let reopened = try fixture.open()

        XCTAssertTrue(fixture.scope.events.isEmpty)
        XCTAssertEqual(reopened.resolvingSymlinksInPath(), migrated.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: reopened), fixture.sourceBytes)
        try fixture.assertSourcesAndUnrelatedBookUnchanged()
    }

    func testUnknownBookDoesNotAcquireScopeOrMutateCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }

        XCTAssertThrowsError(try fixture.open(id: "missing-book")) { error in
            XCTAssertEqual((error as NSError).domain, "LibraryStore")
            XCTAssertEqual((error as NSError).code, 404)
        }

        XCTAssertTrue(fixture.scope.events.isEmpty)
        XCTAssertEqual(fixture.library.books, [fixture.book, fixture.otherBook])
        XCTAssertEqual(fixture.defaults.data(forKey: "library"), fixture.initialIndex)
        try fixture.assertSourcesAndUnrelatedBookUnchanged()
    }

    func testInvalidBookmarkDoesNotAcquireScopeOrCopyAnyFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var invalid = fixture.book
        invalid.bookmark = Data([0, 1, 2])
        fixture.library.update(invalid)
        try fixture.library.flushPersistenceSync()
        let previousIndex = fixture.defaults.data(forKey: "library")

        XCTAssertThrowsError(try fixture.open())

        XCTAssertTrue(fixture.scope.events.isEmpty)
        XCTAssertEqual(fixture.library.books, [invalid, fixture.otherBook])
        XCTAssertEqual(fixture.defaults.data(forKey: "library"), previousIndex)
        try fixture.assertSourcesAndUnrelatedBookUnchanged()
    }

    private final class Fixture {
        let suite = "legacy-security-scope-\(UUID().uuidString)"
        let defaults: UserDefaults
        let root: URL
        let libraryDirectory: URL
        let source: URL
        let sourceBytes: Data
        let otherSource: URL
        let otherBytes: Data
        let book: BookEntity
        let otherBook: BookEntity
        let initialIndex: Data
        let scope: LegacyScopeProbe
        let library: LibraryStore

        init(grantsAccess: Bool = true, failsCopy: Bool = false) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite).resolvingSymlinksInPath()
            libraryDirectory = root.appendingPathComponent("library")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appendingPathComponent("Legacy.epub")
            otherSource = root.appendingPathComponent("Unrelated.epub")
            let generated = try EpubFixture.createWithChapter(body: "Legacy source for scoped migration.")
            defer { try? FileManager.default.removeItem(at: generated) }
            sourceBytes = try Data(contentsOf: generated)
            try sourceBytes.write(to: source)
            let otherGenerated = try EpubFixture.createWithChapter(body: "Unrelated source must remain unchanged.")
            defer { try? FileManager.default.removeItem(at: otherGenerated) }
            otherBytes = try Data(contentsOf: otherGenerated)
            try otherBytes.write(to: otherSource)
            book = BookEntity(id: try LibraryImportFiles.contentHash(of: source), title: "Legacy",
                              bookmark: try LibraryBookmarkAccess.makeBookmark(for: source),
                              displayFilename: source.lastPathComponent, addedAt: .distantPast)
            otherBook = BookEntity(id: try LibraryImportFiles.contentHash(of: otherSource), title: "Unrelated",
                                   bookmark: try LibraryBookmarkAccess.makeBookmark(for: otherSource),
                                   displayFilename: otherSource.lastPathComponent, addedAt: .distantPast)
            initialIndex = try JSONEncoder().encode([book, otherBook])
            defaults.set(initialIndex, forKey: "library")
            scope = LegacyScopeProbe(grantsAccess: grantsAccess)
            library = LibraryStore(defaults: defaults, defaultsKey: "library",
                                   fileManager: LegacyScopeFileManager(scope: scope, failsCopy: failsCopy),
                                   importDirectory: libraryDirectory)
        }

        func open(id: String? = nil) throws -> URL {
            try library.openBookFile(id: id ?? book.id, startSecurityScope: scope.start, stopSecurityScope: scope.stop)
        }

        func reloadedLibrary() -> LibraryStore {
            LibraryStore(defaults: defaults, defaultsKey: "library", importDirectory: libraryDirectory)
        }

        func assertSourcesAndUnrelatedBookUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: otherSource), otherBytes, file: file, line: line)
            XCTAssertEqual(library.books.first { $0.id == otherBook.id }, otherBook, file: file, line: line)
        }

        func cleanUp() {
            try? library.flushPersistenceSync()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
#endif
