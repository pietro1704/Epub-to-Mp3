import XCTest
@testable import EpubToMp3

final class ReaderProgressStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "test.readerProgress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testSaveAndReadRoundTrip() {
        let defaults = makeDefaults()
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 3, offsetFraction: 0.42, defaults: defaults)

        let entry = ReaderProgressStore.read(bookId: "b1", defaults: defaults)
        XCTAssertEqual(entry?.chapterIndex, 3)
        XCTAssertEqual(entry?.offsetFraction ?? -1, 0.42, accuracy: 0.0001)
    }

    func testReadMissingBookReturnsNil() {
        let defaults = makeDefaults()
        XCTAssertNil(ReaderProgressStore.read(bookId: "missing", defaults: defaults))
    }

    func testOffsetFractionIsClamped() {
        let defaults = makeDefaults()
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 0, offsetFraction: 1.7, defaults: defaults)
        ReaderProgressStore.save(bookId: "b2", chapterIndex: 0, offsetFraction: -0.3, defaults: defaults)

        XCTAssertEqual(ReaderProgressStore.read(bookId: "b1", defaults: defaults)?.offsetFraction, 1.0)
        XCTAssertEqual(ReaderProgressStore.read(bookId: "b2", defaults: defaults)?.offsetFraction, 0.0)
    }

    func testSaveOverwritesPreviousEntryForSameBook() {
        let defaults = makeDefaults()
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 1, offsetFraction: 0.1, defaults: defaults)
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 5, offsetFraction: 0.9, defaults: defaults)

        let entry = ReaderProgressStore.read(bookId: "b1", defaults: defaults)
        XCTAssertEqual(entry?.chapterIndex, 5)
        XCTAssertEqual(entry?.offsetFraction, 0.9)
    }

    func testEvictRemovesSingleBook() {
        let defaults = makeDefaults()
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 1, offsetFraction: 0.5, defaults: defaults)
        ReaderProgressStore.save(bookId: "b2", chapterIndex: 1, offsetFraction: 0.5, defaults: defaults)

        ReaderProgressStore.evict(bookId: "b1", defaults: defaults)

        XCTAssertNil(ReaderProgressStore.read(bookId: "b1", defaults: defaults))
        XCTAssertNotNil(ReaderProgressStore.read(bookId: "b2", defaults: defaults))
    }

    func testPruneOrphansDropsMissingBooks() {
        let defaults = makeDefaults()
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 1, offsetFraction: 0.5, defaults: defaults)
        ReaderProgressStore.save(bookId: "orphan", chapterIndex: 1, offsetFraction: 0.5, defaults: defaults)

        let removed = ReaderProgressStore.pruneOrphans(validBookIds: ["b1"], defaults: defaults)

        XCTAssertEqual(removed, 1)
        XCTAssertNotNil(ReaderProgressStore.read(bookId: "b1", defaults: defaults))
        XCTAssertNil(ReaderProgressStore.read(bookId: "orphan", defaults: defaults))
    }

    func testPruneOrphansNoOpWhenAllValid() {
        let defaults = makeDefaults()
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 1, offsetFraction: 0.5, defaults: defaults)

        let removed = ReaderProgressStore.pruneOrphans(validBookIds: ["b1"], defaults: defaults)

        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(ReaderProgressStore.read(bookId: "b1", defaults: defaults))
    }

    func testCorruptDataIsIgnoredNotCrashing() {
        let defaults = makeDefaults()
        defaults.set(Data("{invalid json".utf8), forKey: "readerProgress.v1")

        XCTAssertNil(ReaderProgressStore.read(bookId: "b1", defaults: defaults))
        // Recovers cleanly — a subsequent save must not throw or crash.
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 1, offsetFraction: 0.5, defaults: defaults)
        XCTAssertEqual(ReaderProgressStore.read(bookId: "b1", defaults: defaults)?.chapterIndex, 1)
    }
}
