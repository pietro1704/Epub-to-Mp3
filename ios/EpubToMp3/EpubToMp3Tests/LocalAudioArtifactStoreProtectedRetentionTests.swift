import Foundation
import XCTest

@testable import EpubToMp3

extension LocalAudioArtifactStoreTests {
    func testRemovingDownloadedChapterClearsPlaybackRetentionAcrossRegeneration() async throws {
        try await assertExplicitRemovalClearsPlaybackRetention(removeWholeBook: false)
    }

    func testClearingDownloadedBookClearsPlaybackRetentionAcrossRegeneration() async throws {
        try await assertExplicitRemovalClearsPlaybackRetention(removeWholeBook: true)
    }

    func testPromotingAvailableArtifactKeepsItsCanonicalFile() async throws {
        let store = LocalAudioArtifactStore(root: root)
        let bytes = Data(repeating: 0xA5, count: 1_024)
        let url = try XCTUnwrap(try seedAvailable(author: "Author", chapters: [(1, "Chapter One")], bytes: bytes)[1])

        guard let before = try artifact(1) else {
            return XCTFail("The available chapter must be represented in the manifest.")
        }
        try await store.promote(bookID: "book-id", chapterIndex: 1)
        guard let after = try artifact(1) else {
            return XCTFail("Promotion must preserve the chapter manifest entry.")
        }

        XCTAssertEqual(before.relativePath, after.relativePath)
        XCTAssertEqual(after.retention, .downloaded)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPromotingAvailableSelectionPersistsOnlyTheRequestedArtifacts() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try seedAvailable(chapters: [(0, "First"), (1, "Second")], bytes: Data(repeating: 0xA5, count: 1_024))

        let promoted = try await store.promoteAvailable(
            bookID: "book-id",
            chapterIndices: [1]
        )
        let first = try artifact(0)
        let second = try artifact(1)

        XCTAssertEqual(promoted, [1])
        XCTAssertEqual(first?.retention, .temporary)
        XCTAssertEqual(second?.retention, .downloaded)
    }

    func testPromotingCompletedBookSurvivesTemporaryCacheCleanupAndRestart() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try seedAvailable(chapters: [(0, "First"), (1, "Second")], bytes: Data(repeating: 0xA5, count: 1_024))

        let promoted = try await store.promoteAvailable(bookID: "book-id")
        XCTAssertEqual(promoted, [0, 1])
        try await store.clearTemporaryAudio()

        let reopenedStore = LocalAudioArtifactStore(root: root)
        let snapshot = try await reopenedStore.playableSnapshot(
            bookID: "book-id", engine: "edge", voice: "voice", language: nil)
        let downloaded = try LocalAudioArtifactFixture.downloadedIndices(root: root, bookID: "book-id")
        XCTAssertEqual(snapshot?.state, "finished")
        XCTAssertEqual(downloaded, [0, 1])
    }

    func testDownloadedBookSummaryCountsOnlyPromotedChapters() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try seedAvailable(chapters: [(0, "One"), (1, "Two")], bytes: Data(repeating: 0xAA, count: 64))

        try await store.promote(bookID: "book-id", chapterIndex: 0)
        let partial = try await store.downloadedBooks()
        XCTAssertEqual(partial.map(\.chapterCount), [1])
        XCTAssertEqual(try LocalAudioArtifactFixture.downloadedIndices(root: root, bookID: "book-id"), [0])

        try await store.promote(bookID: "book-id", chapterIndex: 1)
        let complete = try await store.downloadedBooks()
        XCTAssertEqual(complete.map(\.chapterCount), [2])
        XCTAssertEqual(try LocalAudioArtifactFixture.downloadedIndices(root: root, bookID: "book-id"), [0, 1])
    }

    func testDownloadedBooksSummarizeOnlyProtectedAvailableAudio() async throws {
        let store = LocalAudioArtifactStore(root: root)
        for bookID in ["temporary-book", "downloaded-book"] {
            try seedAvailable(
                bookID: bookID,
                title: bookID == "downloaded-book" ? "Downloaded Book" : "Temporary Book",
                author: "Author",
                chapters: [(0, "Chapter")],
                bytes: Data(repeating: 0xA1, count: 256)
            )
        }
        try await store.promote(bookID: "downloaded-book", chapterIndex: 0)

        let books = try await store.downloadedBooks()

        XCTAssertEqual(books, [
            .init(
                bookID: "downloaded-book",
                title: "Downloaded Book",
                author: "Author",
                chapterCount: 1,
                byteCount: 256
            )
        ])
    }

    func testPromotionMakesOnlyTheExplicitDownloadEligibleForBackup() async throws {
        let store = LocalAudioArtifactStore(root: root)
        let url = try XCTUnwrap(try seedAvailable(chapters: [(0, "Chapter")], bytes: Data(repeating: 0xBA, count: 64))[0])

        let temporaryValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(temporaryValues.isExcludedFromBackup, true)

        try await store.promote(bookID: "book-id", chapterIndex: 0)
        let promoted = try artifact(0)
        XCTAssertEqual(promoted?.retention, .downloaded)

        #if targetEnvironment(simulator)
        // CoreSimulator reports its temporary test container as excluded even
        // after clearing the per-file attribute. The manifest remains the
        // durable source of truth and is verified above on this platform.
        #else
        // The store changes the file through its own URL. Read back the
        // filesystem policy, not this test URL's cached pre-promotion value.
        var refreshedURL = url
        refreshedURL.removeAllCachedResourceValues()
        let downloadedValues = try refreshedURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(downloadedValues.isExcludedFromBackup, false)

        // A relaunched store repairs file policies from the manifest on read.
        let restoredStore = LocalAudioArtifactStore(root: root)
        _ = try await restoredStore.playableSnapshot(bookID: "book-id", engine: "edge", voice: "voice", language: nil)
        refreshedURL.removeAllCachedResourceValues()
        let refreshedValues = try refreshedURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(refreshedValues.isExcludedFromBackup, false)
        #endif
    }
}
