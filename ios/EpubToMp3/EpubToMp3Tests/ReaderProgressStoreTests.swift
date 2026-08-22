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

    func testNegativeChapterIndexIsClampedForNewAndLegacyProgress() {
        let defaults = makeDefaults()
        let legacy = #"{"legacy":{"chapterIndex":-4,"offsetFraction":0.5}}"#
        defaults.set(Data(legacy.utf8), forKey: "readerProgress.v1")

        XCTAssertEqual(ReaderProgressStore.read(bookId: "legacy", defaults: defaults)?.chapterIndex, 0)

        ReaderProgressStore.save(bookId: "new", chapterIndex: -2, offsetFraction: 0.5, defaults: defaults)
        XCTAssertEqual(ReaderProgressStore.read(bookId: "new", defaults: defaults)?.chapterIndex, 0)
    }

    func testInitialChapterSelectionRejectsEmptyContentAndClampsProgress() {
        XCTAssertNil(ReaderInitialChapter.index(selectedChapter: 0, chapterCount: 0))
        XCTAssertEqual(ReaderInitialChapter.index(selectedChapter: -3, chapterCount: 4), 0)
        XCTAssertEqual(ReaderInitialChapter.index(selectedChapter: 99, chapterCount: 4), 3)
    }

    func testFirstOpenSkipsCoverBoilerplate() {
        let chapters = [
            EbookFulltext.Chapter(index: 1, name: "Cover", sourcePath: nil, text: "Cover", speechText: nil, html: nil, css: nil, charCount: 5, segments: nil, resources: nil, footnotes: nil, contentKind: nil),
            EbookFulltext.Chapter(index: 2, name: "Title Page", sourcePath: nil, text: "Title Page", speechText: nil, html: nil, css: nil, charCount: 10, segments: nil, resources: nil, footnotes: nil, contentKind: nil),
            EbookFulltext.Chapter(index: 3, name: "Chapter One", sourcePath: nil, text: String(repeating: "Readable text. ", count: 100), speechText: nil, html: nil, css: nil, charCount: 1_500, segments: nil, resources: nil, footnotes: nil, contentKind: nil),
        ]

        XCTAssertEqual(ReaderInitialChapter.firstSubstantiveIndex(in: chapters), 2)
    }

    func testInitialIndexUsesSavedProgressOrSkipsCoverBoilerplate() {
        let chapters = [
            EbookFulltext.Chapter(index: 1, name: "Cover", sourcePath: nil, text: "Cover", speechText: nil, html: nil, css: nil, charCount: 5, segments: nil, resources: nil, footnotes: nil, contentKind: nil),
            EbookFulltext.Chapter(index: 2, name: "Chapter One", sourcePath: nil, text: String(repeating: "Readable text. ", count: 100), speechText: nil, html: nil, css: nil, charCount: 1_500, segments: nil, resources: nil, footnotes: nil, contentKind: nil),
        ]

        XCTAssertEqual(ReaderInitialChapter.index(progress: nil, in: chapters), 1)
        XCTAssertEqual(
            ReaderInitialChapter.index(
                progress: .init(chapterIndex: 0, offsetFraction: 0),
                in: chapters
            ),
            0
        )
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

    func testLegacyEntryWithoutCharacterOffsetStillDecodes() {
        let defaults = makeDefaults()
        let legacy = #"{"b1":{"chapterIndex":2,"offsetFraction":0.5}}"#
        defaults.set(Data(legacy.utf8), forKey: "readerProgress.v1")

        let entry = ReaderProgressStore.read(bookId: "b1", defaults: defaults)
        XCTAssertEqual(entry?.chapterIndex, 2)
        XCTAssertEqual(entry?.offsetFraction, 0.5)
        XCTAssertNil(entry?.characterOffset)
    }

    func testCharacterOffsetRoundTrips() {
        let defaults = makeDefaults()
        ReaderProgressStore.save(bookId: "b1", chapterIndex: 1, offsetFraction: 0.25,
                                 characterOffset: 123, defaults: defaults)

        XCTAssertEqual(ReaderProgressStore.read(bookId: "b1", defaults: defaults)?.characterOffset, 123)
    }
}
