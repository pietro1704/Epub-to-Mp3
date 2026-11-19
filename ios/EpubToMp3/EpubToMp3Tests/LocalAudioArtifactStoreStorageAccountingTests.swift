import Foundation
import XCTest

@testable import EpubToMp3

extension LocalAudioArtifactStoreTests {
    func testTemporaryEvictionCandidatesNeverContainDownloadedBooks() async throws {
        let store = LocalAudioArtifactStore(root: root)
        for bookID in ["temporary-book", "downloaded-book"] {
            try seedAvailable(bookID: bookID, title: bookID, chapters: [(0, "Chapter")],
                              bytes: Data(repeating: 0xFF, count: 64))
        }

        try await store.promote(bookID: "downloaded-book", chapterIndex: 0)

        let candidates = try await store.temporaryBookIDsEligibleForEviction()
        XCTAssertEqual(candidates, ["temporary-book"])
    }

    func testStorageUsageSeparatesTemporaryFromDownloadedAudio() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try seedAvailable(chapters: [(0, "Temporary"), (1, "Downloaded")], bytes: Data(repeating: 0xFF, count: 128))
        try await store.promote(bookID: "book-id", chapterIndex: 1)

        let usage = LocalAudioStorageUsage.storageUsage(root: root)
        XCTAssertEqual(usage.temporaryBytes, 128)
        XCTAssertEqual(usage.downloadedBytes, 128)
    }

    func testClearingTemporaryAudioPreservesDownloadedChapters() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try seedAvailable(chapters: [(0, "Temporary"), (1, "Downloaded")], bytes: Data(repeating: 0xFF, count: 64))
        try await store.promote(bookID: "book-id", chapterIndex: 1)

        try await store.clearTemporaryAudio()

        let temporary = try artifact(0)
        let downloaded = try artifact(1)
        XCTAssertEqual(temporary?.state, .pending)
        XCTAssertEqual(downloaded?.state, .available)
        XCTAssertEqual(downloaded?.retention, .downloaded)
    }

    func testReadingAndSummarizingStoredAudioNeverEvictsStreamedOrDownloadedAudio() async throws {
        let store = LocalAudioArtifactStore(root: root)
        var urls: [URL] = []
        for bookID in ["temporary-book", "downloaded-book"] {
            urls += try seedAvailable(bookID: bookID, title: bookID, chapters: [(0, "Chapter")],
                                      bytes: Data(repeating: 0xDF, count: 64)).values
        }
        try await store.promote(bookID: "downloaded-book", chapterIndex: 0)

        // Launch-time and Settings reads must not remove listener media.
        _ = try await store.temporaryBookIDsEligibleForEviction()
        _ = try await store.downloadedBooks()
        _ = LocalAudioStorageUsage.storageUsage(root: root)
        for bookID in ["temporary-book", "downloaded-book"] {
            _ = try await store.playableSnapshot(bookID: bookID, engine: "edge", voice: "voice", language: nil)
        }
        let temporary = try artifact("temporary-book", 0)
        let downloaded = try artifact("downloaded-book", 0)

        XCTAssertEqual(temporary?.state, .available)
        XCTAssertEqual(downloaded?.state, .available)
        XCTAssertEqual(downloaded?.retention, .downloaded)
        for url in urls { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testRemovingBookAudioDeletesItsManifestAndChapters() async throws {
        let store = LocalAudioArtifactStore(root: root)
        let chapterURL = try XCTUnwrap(
            try seedAvailable(chapters: [(0, "First")], bytes: Data(repeating: 0xD1, count: 32))[0])

        try await store.removeAllAudio(bookID: "book-id")

        let manifest = try LocalAudioArtifactFixture.manifest(root: root, bookID: "book-id")
        XCTAssertNil(manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: chapterURL.path))
    }
}
