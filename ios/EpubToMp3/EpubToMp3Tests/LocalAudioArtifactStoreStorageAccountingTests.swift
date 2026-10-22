import Foundation
import XCTest

@testable import EpubToMp3

extension LocalAudioArtifactStoreTests {
    func testTemporaryEvictionCandidatesNeverContainDownloadedBooks() async throws {
        let store = LocalAudioArtifactStore(root: root)
        for bookID in ["temporary-book", "downloaded-book"] {
            try await store.prepare(
                bookID: bookID,
                bookTitle: bookID,
                author: nil,
                chapters: [.init(index: 0, title: "Chapter")]
            )
            let url = try await store.canonicalURL(bookID: bookID, chapterIndex: 0)
            try Data(repeating: 0xFF, count: 64).write(to: url)
            try await store.markAvailable(bookID: bookID, chapterIndex: 0)
        }

        try await store.promote(bookID: "downloaded-book", chapterIndex: 0)

        let candidates = try await store.temporaryBookIDsEligibleForEviction()
        XCTAssertEqual(candidates, ["temporary-book"])
    }

    func testStorageUsageSeparatesTemporaryFromDownloadedAudio() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "Temporary"), .init(index: 1, title: "Downloaded")]
        )
        for index in [0, 1] {
            let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: index)
            try Data(repeating: 0xFF, count: 128).write(to: url)
            try await store.markAvailable(bookID: "book-id", chapterIndex: index)
        }
        try await store.promote(bookID: "book-id", chapterIndex: 1)

        let usage = LocalAudioStorageUsage.storageUsage(root: root)
        XCTAssertEqual(usage.temporaryBytes, 128)
        XCTAssertEqual(usage.downloadedBytes, 128)
    }

    func testClearingTemporaryAudioPreservesDownloadedChapters() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "Temporary"), .init(index: 1, title: "Downloaded")]
        )
        for index in [0, 1] {
            let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: index)
            try Data(repeating: 0xFF, count: 64).write(to: url)
            try await store.markAvailable(bookID: "book-id", chapterIndex: index)
        }
        try await store.promote(bookID: "book-id", chapterIndex: 1)

        try await store.clearTemporaryAudio()

        let temporary = try await store.artifact(bookID: "book-id", chapterIndex: 0)
        let downloaded = try await store.artifact(bookID: "book-id", chapterIndex: 1)
        XCTAssertEqual(temporary?.state, .pending)
        XCTAssertEqual(downloaded?.state, .available)
        XCTAssertEqual(downloaded?.retention, .downloaded)
    }

    func testAutomaticEvictionPreservesStreamedAndDownloadedAudio() async throws {
        let store = LocalAudioArtifactStore(root: root)
        for bookID in ["temporary-book", "downloaded-book"] {
            try await store.prepare(
                bookID: bookID,
                bookTitle: bookID,
                author: nil,
                chapters: [.init(index: 0, title: "Chapter")]
            )
            let url = try await store.canonicalURL(bookID: bookID, chapterIndex: 0)
            try Data(repeating: 0xDF, count: 64).write(to: url)
            try await store.markAvailable(bookID: bookID, chapterIndex: 0)
        }
        try await store.promote(bookID: "downloaded-book", chapterIndex: 0)

        let evicted = try await store.evictTemporaryAudio(toMaximumBytes: 0)
        let temporary = try await store.artifact(bookID: "temporary-book", chapterIndex: 0)
        let downloaded = try await store.artifact(bookID: "downloaded-book", chapterIndex: 0)

        XCTAssertEqual(evicted, [])
        XCTAssertEqual(temporary?.state, .available)
        XCTAssertEqual(downloaded?.state, .available)
        XCTAssertEqual(downloaded?.retention, .downloaded)
    }

    func testRemovingBookAudioDeletesItsManifestAndChapters() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "First")]
        )
        let chapterURL = try await store.canonicalURL(bookID: "book-id", chapterIndex: 0)
        try Data(repeating: 0xD1, count: 32).write(to: chapterURL)
        try await store.markAvailable(bookID: "book-id", chapterIndex: 0)

        try await store.removeAllAudio(bookID: "book-id")

        let manifest = try await store.manifest(bookID: "book-id")
        XCTAssertNil(manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chapterURL.path))
    }
}
