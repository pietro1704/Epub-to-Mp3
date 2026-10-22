#if canImport(AVFoundation) && canImport(MediaPlayer)
import Foundation
import XCTest
@testable import EpubToMp3

final class PlaybackRetentionPersistenceTests: XCTestCase {
    @MainActor
    func testAudibleRetentionDeduplicatesPendingAndConfirmedIdentity() async throws {
        var calls: [(String, Int)] = []
        var release: CheckedContinuation<Void, Never>?
        let owner = PlaybackResumeStore(store: ResumeStore(), retainArtifact: { book, chapter in
            calls.append((book, chapter))
            if calls.count == 1 { await withCheckedContinuation { release = $0 } }
        })
        let first = try XCTUnwrap(owner.requestArtifactRetention(bookID: "raw-book", chapterIndex: 7))
        for _ in 0..<200 where release == nil { await Task.yield() }
        guard let continuation = release else { first.cancel(); return XCTFail("Retention did not start") }
        let duplicate = try XCTUnwrap(owner.requestArtifactRetention(bookID: "raw-book", chapterIndex: 7))
        XCTAssertEqual(calls.count, 1, "Pending durable intent cannot be submitted twice")
        continuation.resume()
        await first.value
        await duplicate.value
        XCTAssertNil(owner.requestArtifactRetention(bookID: "raw-book", chapterIndex: 7))
        let next = try XCTUnwrap(owner.requestArtifactRetention(bookID: "raw-book", chapterIndex: 8))
        await next.value
        XCTAssertEqual(calls.map { $0.0 }, ["raw-book", "raw-book"])
        XCTAssertEqual(calls.map { $0.1 }, [7, 8])
    }

    @MainActor
    func testRetentionFailureIsRetryableAndStopDoesNotCancelAudibleIntent() async throws {
        enum Failure: Error { case save }
        var attempts = 0
        let owner = PlaybackResumeStore(store: ResumeStore(), retainArtifact: { _, _ in
            attempts += 1
            if attempts == 1 { throw Failure.save }
        })
        let first = try XCTUnwrap(owner.requestArtifactRetention(bookID: "book", chapterIndex: 2))
        await first.value
        let retry = try XCTUnwrap(owner.requestArtifactRetention(bookID: "book", chapterIndex: 2))
        owner.resetRetention()
        await retry.value
        XCTAssertEqual(attempts, 2, "A failed durable write cannot latch success")
        let newSession = try XCTUnwrap(owner.requestArtifactRetention(bookID: "book", chapterIndex: 2))
        await newSession.value
        XCTAssertEqual(attempts, 3, "An old completion cannot latch another generation")
        XCTAssertNil(owner.requestArtifactRetention(bookID: "book", chapterIndex: 2))
    }
}
#endif
