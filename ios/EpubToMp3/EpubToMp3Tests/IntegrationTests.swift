import XCTest
@testable import EpubToMp3

/// End-to-end tests that exercise the full local stack:
/// fixture EPUB → ZipReader → EpubMetadataReader → LibraryStore.
/// These don't touch the backend; they validate the on-device path
/// the user hits when importing a book from disk.
final class IntegrationTests: XCTestCase {

    // MARK: - ZipReader

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
            // Access-denied (1) or read failure (2); the localized text names the file.
            XCTAssertTrue([1, 2].contains(nse.code), "unexpected error code: \(nse.code)")
            XCTAssertTrue(
                nse.localizedDescription.contains(url.lastPathComponent),
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
}
