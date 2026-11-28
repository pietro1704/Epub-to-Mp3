import XCTest
@testable import EpubToMp3

/// A book without a cover shows one drawn from its file name (Rust owns label and colour).
final class FilenameCoverTests: XCTestCase {
    private let suite = "filename-cover-\(UUID().uuidString)"
    private lazy var defaults = UserDefaults(suiteName: suite)!

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func book(id: String, file: String, cover: Data? = nil) -> BookEntity {
        BookEntity(id: id, title: "Synthetic", bookmark: Data([1]), displayFilename: file,
                   addedAt: Date(timeIntervalSince1970: 0), coverPNG: cover)
    }

    private func seed(_ books: [BookEntity]) throws {
        defaults.set(try JSONEncoder().encode(books), forKey: "library")
    }

    func testRustNamesAndColoursTheCover() throws {
        let cover = try ConverterFFIAdapter().filenameCover(for: "Meu_livro-final.v2.pdf")
        XCTAssertEqual(cover.label, "Meu livro final v2")
        XCTAssertEqual(cover.backgroundRgb.count, 3)
        XCTAssertEqual(try ConverterFFIAdapter().filenameCover(for: "Meu_livro-final.v2.pdf"), cover)
    }

    func testACoverlessBookGetsACoverThatNeverPosesAsTheRealOne() throws {
        try seed([book(id: "a", file: "synthetic_story.epub")])
        let store = LibraryStore(defaults: defaults, defaultsKey: "library")
        let loaded = try XCTUnwrap(store.books.first)

        XCTAssertNil(loaded.coverPNG, "Cover discovery must still see a missing cover")
        let drawn = try XCTUnwrap(loaded.displayCoverPNG)
        XCTAssertEqual(Array(drawn.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(loaded.coverCacheKey, "a#generated")

        var found = loaded
        found.coverPNG = Data([7])
        XCTAssertEqual(found.displayCoverPNG, Data([7]))
        XCTAssertEqual(found.coverCacheKey, "a")
    }

    /// The widget reads the saved index and cannot call Rust.
    func testTheSavedIndexCarriesTheCoverToTheWidget() throws {
        try seed([book(id: "a", file: "synthetic_story.epub"), book(id: "b", file: "b.epub", cover: Data([7]))])
        let store = LibraryStore(defaults: defaults, defaultsKey: "library")
        XCTAssertNotNil(store.books[0].displayCoverPNG)
        // The next ordinary save, here a playback, carries the drawn cover.
        store.recordPlayback(of: "a")
        try store.flushPersistenceSync()
        let saved = try JSONDecoder().decode([BookEntity].self, from: XCTUnwrap(defaults.data(forKey: "library")))

        XCTAssertEqual(saved[0].displayCoverPNG, store.books[0].displayCoverPNG)
        XCTAssertNotNil(saved[0].generatedCoverPNG)
        XCTAssertNil(saved[1].generatedCoverPNG)
    }
}
