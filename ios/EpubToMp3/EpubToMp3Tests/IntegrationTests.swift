import XCTest
@testable import EpubToMp3

/// End-to-end tests that exercise the full local stack:
/// fixture EPUB → ZipReader → EpubMetadataReader → LibraryStore.
/// These don't touch the backend; they validate the on-device path
/// the user hits when importing a book from disk.
final class IntegrationTests: XCTestCase {

    // MARK: - ZipReader

    func testZipReaderExtractsStoredAndDeflatedMembers() throws {
        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }

        // STORE entry — mimetype is required to be the first entry of
        // every EPUB and stored uncompressed per spec.
        let mimetype = ZipReader.extract(member: "mimetype", from: url)
        XCTAssertEqual(mimetype.flatMap { String(data: $0, encoding: .utf8) },
                       "application/epub+zip")

        // DEFLATE entry.
        let container = ZipReader.extract(member: "META-INF/container.xml",
                                          from: url)
        XCTAssertNotNil(container)
        XCTAssertTrue(
            String(data: container!, encoding: .utf8)!
                .contains("OEBPS/content.opf")
        )
    }

    func testZipReaderReturnsNilForMissingMember() throws {
        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ZipReader.extract(member: "no-such-member.xml", from: url))
    }

    // MARK: - EpubMetadataReader

    func testReadMetadataExtractsTitleAuthorAndCover() throws {
        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try EpubMetadataReader.readMetadata(from: url)
        XCTAssertEqual(payload.title, EpubFixture.title)
        XCTAssertEqual(payload.author, EpubFixture.author)
        XCTAssertEqual(payload.cover, EpubFixture.coverPNG)
    }

    func testReadMetadataReturnsEmptyPayloadForMalformedArchive() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).epub")
        try Data("not a zip".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = try EpubMetadataReader.readMetadata(from: url)
        XCTAssertNil(payload.title)
        XCTAssertNil(payload.author)
        XCTAssertNil(payload.cover)
    }

    // MARK: - LibraryStore importBook

    func testImportBookEnrichesEntryWithEpubMetadata() throws {
        let suite = "library.int.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")

        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }

        let book = try store.importBook(from: url)
        XCTAssertEqual(book.title, EpubFixture.title)
        XCTAssertEqual(book.author, EpubFixture.author)
        XCTAssertEqual(book.coverPNG, EpubFixture.coverPNG)
        XCTAssertEqual(book.displayFilename, url.lastPathComponent)
        XCTAssertEqual(store.books.count, 1)
    }

    func testImportBookSurfacesReadableErrorForUnreadableFile() {
        let suite = "library.err.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")

        let url = URL(fileURLWithPath: "/this/path/does/not/exist.epub")
        XCTAssertThrowsError(try store.importBook(from: url)) { error in
            let nse = error as NSError
            XCTAssertEqual(nse.domain, "LibraryStore")
            XCTAssertTrue(
                nse.localizedDescription.contains("Cannot read") ||
                nse.localizedDescription.contains("Failed to read"),
                "expected human-readable error, got: \(nse.localizedDescription)"
            )
        }
    }

    func testImportBookPersistsAcrossStoreReinstantiation() throws {
        let suite = "library.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }

        let s1 = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        let imported = try s1.importBook(from: url)

        let s2 = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        XCTAssertEqual(s2.books.count, 1)
        XCTAssertEqual(s2.books.first?.id, imported.id)
        XCTAssertEqual(s2.books.first?.title, EpubFixture.title)
    }

    func testRemoveDropsEntryFromPersistedStore() throws {
        let suite = "library.rm.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let url = try EpubFixture.create()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        let book = try store.importBook(from: url)
        store.remove(id: book.id)

        let reloaded = LibraryStore(defaults: defaults, defaultsKey: "library.books.v1")
        XCTAssertTrue(reloaded.books.isEmpty)
    }
}
