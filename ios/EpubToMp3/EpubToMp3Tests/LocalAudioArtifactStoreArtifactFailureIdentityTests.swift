import Foundation
import XCTest

@testable import EpubToMp3

extension LocalAudioArtifactStoreTests {
    func testClassifiesCocoaOutOfSpaceAsStoragePressure() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError
        )

        XCTAssertTrue(StoragePressureError.isInsufficientSpace(error))
    }

    func testDoesNotClassifyAnUnrelatedErrorAsStoragePressure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        XCTAssertFalse(StoragePressureError.isInsufficientSpace(error))
    }

    func testPrepareRecoversAnAvailableArtifactWhoseFileWasRemoved() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "Chapter")]
        )
        let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: 0)
        try Data(repeating: 0xEE, count: 32).write(to: url)
        try await store.markAvailable(bookID: "book-id", chapterIndex: 0)
        try FileManager.default.removeItem(at: url)

        let recovered = try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "Chapter")]
        )

        XCTAssertEqual(recovered.chapters.first?.state, .pending)
        XCTAssertEqual(recovered.chapters.first?.byteCount, 0)
    }

    func testStateTransitionsPreserveFailureDetailsUntilAudioBecomesAvailable() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "Chapter")]
        )

        try await store.markGenerating(bookID: "book-id", chapterIndex: 0)
        let generating = try await store.artifact(bookID: "book-id", chapterIndex: 0)
        XCTAssertEqual(generating?.state, .generating)
        try await store.markWaitingForWiFi(bookID: "book-id", chapterIndex: 0)
        let waitingForWiFi = try await store.artifact(bookID: "book-id", chapterIndex: 0)
        XCTAssertEqual(waitingForWiFi?.state, .waitingForWiFi)
        try await store.markFailed(bookID: "book-id", chapterIndex: 0, errorDescription: "Network unavailable")

        let failed = try await store.artifact(bookID: "book-id", chapterIndex: 0)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.retryCount, 1)
        XCTAssertEqual(failed?.lastError, "Network unavailable")

        let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: 0)
        try Data(repeating: 0xC0, count: 32).write(to: url)
        try await store.markAvailable(bookID: "book-id", chapterIndex: 0)
        let available = try await store.artifact(bookID: "book-id", chapterIndex: 0)
        XCTAssertEqual(available?.state, .available)
        XCTAssertNil(available?.lastError)
    }

    func testFailedIndicesIncludeOnlyRetryableChapters() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [
                .init(index: 0, title: "Available"),
                .init(index: 1, title: "Failed"),
                .init(index: 2, title: "Pending")
            ]
        )
        try await store.markFailed(bookID: "book-id", chapterIndex: 1, errorDescription: "Network unavailable")

        let failed = try await store.failedIndices(bookID: "book-id")
        XCTAssertEqual(failed, [1])
    }

    func testCanonicalURLStaysInsideTheStoreForUnsafeBookIdentifiers() async throws {
        let store = LocalAudioArtifactStore(root: root)
        let bookID = "../Book / with symbols"
        try await store.prepare(
            bookID: bookID,
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 3, title: "Chapter")]
        )

        let url = try await store.canonicalURL(bookID: bookID, chapterIndex: 3)
        XCTAssertTrue(url.path.hasPrefix(root.standardizedFileURL.path + "/"))
        XCTAssertEqual(url.lastPathComponent, "chapter-3.mp3")
    }
}
