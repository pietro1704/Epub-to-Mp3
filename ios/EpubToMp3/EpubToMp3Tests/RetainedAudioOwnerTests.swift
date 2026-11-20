import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class RetainedAudioOwnerTests: XCTestCase {
    private var root: URL!
    private var outputs: RustConversionOutputStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetainedAudioOwner-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        outputs = RustConversionOutputStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(job: String, base: Int?) -> JobSnapshot {
        JobSnapshot(jobId: job, state: "finished", bookTitle: "Book", bookAuthor: nil, coverUrl: nil,
            coverMimeType: nil, engine: nil, voice: nil, language: nil, progressPercent: 100,
            chaptersTotal: 0, chaptersCompleted: 0, chapterProgress: [], outputs: nil, logUrl: nil,
            error: nil, lastActivityAt: nil, chapterIndexBase: base)
    }

    /// A finished job as the converter leaves it: the ownership file, optionally
    /// the reader chapter map, and optionally the job record naming its source.
    private func job(_ id: String, book: String, readerMap: Bool = false, source: String? = nil) async throws {
        let lease = try await outputs.begin(bookID: book, jobID: id, cancel: {})
        if readerMap {
            try Data("{}".utf8).write(to: lease.outputDirectory.appendingPathComponent("reader-chapter-map.json"))
        }
        if let source {
            let records = root.appendingPathComponent(".jobs", isDirectory: true)
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["job_id": id, "metadata": ["input": source]])
                .write(to: records.appendingPathComponent("\(id).json"))
        }
        await outputs.finish(lease)
    }

    private func owner(_ job: String, base: Int? = 0) async -> RetainedAudioOwner? {
        await RetainedAudioOwner.resolve(snapshot(job: job, base: base), rustOutputs: outputs)
    }

    func testTheBookComesFromTheStoreJobIDOrTheJobsOwnOwnershipRecord() async throws {
        try await job("reader-epub", book: "book-a", readerMap: true, source: "/books/a.epub")
        try await job("pdf", book: "book-b", source: "/books/b.PDF")
        let embedded = await owner("embedded-abc")
        XCTAssertEqual(embedded, RetainedAudioOwner(bookID: "abc", indexBase: 0))
        let readerEpub = await owner("reader-epub")
        XCTAssertEqual(readerEpub, RetainedAudioOwner(bookID: "book-a", indexBase: 0))
        let pdf = await owner("pdf", base: 1)
        XCTAssertEqual(pdf, RetainedAudioOwner(bookID: "book-b", indexBase: 1),
                       "Only an EPUB has a reader chapter list that can differ from the converter's")
    }

    func testAJobOnTheConvertersOwnChapterAxisIsNotPlacedOnTheBooksAxis() async throws {
        // A manual EPUB conversion numbers chapters as the converter sees them.
        try await job("manual-epub", book: "book-a", source: "/books/a.epub")
        try await job("no-record", book: "book-a")
        let manual = await owner("manual-epub")
        XCTAssertNil(manual)
        let unrecorded = await owner("no-record")
        XCTAssertNil(unrecorded, "Without a record of its source, the axis is not known")
    }

    func testNothingIsGuessedWithoutADeclaredAxisOrAnOwnershipRecord() async throws {
        try await job("job-1", book: "book-hash", readerMap: true)
        // A job folder that lost its ownership file names no book.
        let orphan = root.appendingPathComponent("orphan", isDirectory: true)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: orphan.appendingPathComponent("reader-chapter-map.json"))
        let candidates: [(String, Int?)] = [("job-1", nil), ("job-1", 2), ("unknown-job", 0), ("orphan", 0),
                                            ("embedded-", 0), ("../job-1", 0)]
        for (jobID, base) in candidates {
            let resolved = await owner(jobID, base: base)
            XCTAssertNil(resolved, jobID)
        }
    }

    func testOneBasedSnapshotsMapOntoTheZeroBasedStoreAxis() {
        let owner = RetainedAudioOwner(bookID: "book", indexBase: 1)
        XCTAssertEqual(owner.storeIndex(forSnapshotIndex: 1), 0)
        XCTAssertEqual(owner.storeIndex(forSnapshotIndex: 5), 4)
        XCTAssertNil(owner.storeIndex(forSnapshotIndex: 0))
        XCTAssertEqual(owner.snapshotIndex(forStoreIndex: 4), 5)
    }
}
