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

    func testDotAndEmptySanitizedIdentifiersCannotRemoveTheStoreOrSiblingAudio() async throws {
        for bookID in [".", "..", "/"] {
            // Even the old traversal stays inside this uniquely owned fixture.
            // Never test a parent-segment removal against the system temp root.
            let fixture = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let storage = fixture.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            let outside = fixture.appendingPathComponent("outside-store.bin")
            let marker = storage.appendingPathComponent("store-marker.bin")
            let retainedBytes = Data(repeating: 0xA5, count: 64)
            try retainedBytes.write(to: outside)
            try retainedBytes.write(to: marker)

            let store = LocalAudioArtifactStore(root: storage)
            try await store.prepare(bookID: "retained-book", bookTitle: "Retained", author: nil,
                                    chapters: [.init(index: 0, title: "Retained chapter")])
            let retained = try await store.canonicalURL(bookID: "retained-book", chapterIndex: 0)
            try retainedBytes.write(to: retained)
            try await store.markAvailable(bookID: "retained-book", chapterIndex: 0)

            try await store.prepare(bookID: bookID, bookTitle: "Unsafe identity", author: nil,
                                    chapters: [.init(index: 1, title: "Disposable chapter")])
            let audio = try await store.canonicalURL(bookID: bookID, chapterIndex: 1)
            let bookDirectory = audio.deletingLastPathComponent().deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
            let canonicalStorage = storage.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertTrue(bookDirectory.path.hasPrefix(canonicalStorage.path + "/"), bookID)
            try Data(repeating: 0xB6, count: 32).write(to: audio)
            try await store.markAvailable(bookID: bookID, chapterIndex: 1)
            try await store.removeAllAudio(bookID: bookID)

            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.path), bookID)
            XCTAssertEqual(try Data(contentsOf: outside), retainedBytes, bookID)
            XCTAssertEqual(try Data(contentsOf: marker), retainedBytes, bookID)
            XCTAssertEqual(try Data(contentsOf: retained), retainedBytes, bookID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path), bookID)
        }
    }

    func testCanonicalBookDirectoryPreservesAValidIdentifier() async throws {
        let bookID = "0123456789abcdef-Book_ID"
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(bookID: bookID, bookTitle: "Book", author: nil,
                                chapters: [.init(index: 2, title: "Chapter")])
        let audio = try await store.canonicalURL(bookID: bookID, chapterIndex: 2)
        XCTAssertEqual(audio.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                       bookID)
    }

    func testDotIdentifiersDoNotAliasAnOrdinaryBookDirectory() {
        let files = LocalAudioArtifactFiles(root: root, fileManager: .default)
        let ordinary = files.bookDirectory(bookID: "book").standardizedFileURL
        let dot = files.bookDirectory(bookID: ".").standardizedFileURL
        let parent = files.bookDirectory(bookID: "..").standardizedFileURL
        XCTAssertNotEqual(dot, ordinary)
        XCTAssertNotEqual(parent, ordinary)
        XCTAssertNotEqual(dot, parent)
    }
}
