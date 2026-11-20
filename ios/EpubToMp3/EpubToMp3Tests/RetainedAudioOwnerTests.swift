import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class RetainedAudioOwnerTests: XCTestCase {
    private func snapshot(job: String, base: Int?) -> JobSnapshot {
        JobSnapshot(jobId: job, state: "finished", bookTitle: "Book", bookAuthor: nil, coverUrl: nil,
            coverMimeType: nil, engine: nil, voice: nil, language: nil, progressPercent: 100,
            chaptersTotal: 0, chaptersCompleted: 0, chapterProgress: [], outputs: nil, logUrl: nil,
            error: nil, lastActivityAt: nil, chapterIndexBase: base)
    }

    private func outputs() throws -> RustConversionOutputStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetainedAudioOwner-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return RustConversionOutputStore(root: root)
    }

    func testTheBookComesFromTheStoreJobIDOrTheConversionOwnershipRecord() async throws {
        let outputs = try outputs()
        let lease = try await outputs.begin(bookID: "book-hash", jobID: "job-1", cancel: {})
        await outputs.finish(lease)
        let embedded = await RetainedAudioOwner.resolve(snapshot(job: "embedded-abc", base: 0), rustOutputs: outputs)
        XCTAssertEqual(embedded, RetainedAudioOwner(bookID: "abc", indexBase: 0))
        let converted = await RetainedAudioOwner.resolve(snapshot(job: "job-1", base: 0), rustOutputs: outputs)
        XCTAssertEqual(converted, RetainedAudioOwner(bookID: "book-hash", indexBase: 0))
    }

    func testNothingIsGuessedWithoutADeclaredAxisOrAnOwnershipRecord() async throws {
        let outputs = try outputs()
        let lease = try await outputs.begin(bookID: "book-hash", jobID: "job-1", cancel: {})
        await outputs.finish(lease)
        for candidate in [snapshot(job: "job-1", base: nil), snapshot(job: "job-1", base: 2),
                          snapshot(job: "unknown-job", base: 0), snapshot(job: "embedded-", base: 0),
                          snapshot(job: "../job-1", base: 0)] {
            let owner = await RetainedAudioOwner.resolve(candidate, rustOutputs: outputs)
            XCTAssertNil(owner, candidate.jobId)
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
