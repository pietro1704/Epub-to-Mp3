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
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: "Author",
            chapters: [.init(index: 1, title: "Chapter One")]
        )

        let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: 1)
        let bytes = Data(repeating: 0xA5, count: 1_024)
        try bytes.write(to: url)
        try await store.markAvailable(bookID: "book-id", chapterIndex: 1)

        guard let before = try await store.artifact(bookID: "book-id", chapterIndex: 1) else {
            return XCTFail("The available chapter must be represented in the manifest.")
        }
        try await store.promote(bookID: "book-id", chapterIndex: 1)
        guard let after = try await store.artifact(bookID: "book-id", chapterIndex: 1) else {
            return XCTFail("Promotion must preserve the chapter manifest entry.")
        }

        XCTAssertEqual(before.relativePath, after.relativePath)
        XCTAssertEqual(after.retention, .downloaded)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testPromotingAvailableSelectionPersistsOnlyTheRequestedArtifacts() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [
                .init(index: 0, title: "First"),
                .init(index: 1, title: "Second")
            ]
        )
        for index in [0, 1] {
            let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: index)
            try Data(repeating: 0xA5, count: 1_024).write(to: url)
            try await store.markAvailable(bookID: "book-id", chapterIndex: index)
        }

        let promoted = try await store.promoteAvailable(
            bookID: "book-id",
            chapterIndices: [1]
        )
        let first = try await store.artifact(bookID: "book-id", chapterIndex: 0)
        let second = try await store.artifact(bookID: "book-id", chapterIndex: 1)

        XCTAssertEqual(promoted, [1])
        XCTAssertEqual(first?.retention, .temporary)
        XCTAssertEqual(second?.retention, .downloaded)
    }

    func testPromotingCompletedBookSurvivesTemporaryCacheCleanupAndRestart() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [
                .init(index: 0, title: "First"),
                .init(index: 1, title: "Second")
            ]
        )
        for index in [0, 1] {
            let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: index)
            try Data(repeating: 0xA5, count: 1_024).write(to: url)
            try await store.markAvailable(bookID: "book-id", chapterIndex: index)
        }

        let promoted = try await store.promoteAvailable(bookID: "book-id")
        XCTAssertEqual(promoted, [0, 1])
        try await store.clearTemporaryAudio()

        let reopenedStore = LocalAudioArtifactStore(root: root)
        let hasCompleteAudio = try await reopenedStore.hasCompleteDownloadedAudio(bookID: "book-id")
        let downloaded = try await reopenedStore.downloadedIndices(bookID: "book-id")
        XCTAssertTrue(hasCompleteAudio)
        XCTAssertEqual(downloaded, [0, 1])
    }

    func testCompleteDownloadRequiresEveryChapterToBePromoted() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "One"), .init(index: 1, title: "Two")]
        )
        for index in [0, 1] {
            let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: index)
            try Data(repeating: 0xAA, count: 64).write(to: url)
            try await store.markAvailable(bookID: "book-id", chapterIndex: index)
        }

        try await store.promote(bookID: "book-id", chapterIndex: 0)
        let isIncomplete = try await store.hasCompleteDownloadedAudio(bookID: "book-id")
        XCTAssertFalse(isIncomplete)

        try await store.promote(bookID: "book-id", chapterIndex: 1)
        let isComplete = try await store.hasCompleteDownloadedAudio(bookID: "book-id")
        XCTAssertTrue(isComplete)
    }

    func testDownloadedBooksSummarizeOnlyProtectedAvailableAudio() async throws {
        let store = LocalAudioArtifactStore(root: root)
        for bookID in ["temporary-book", "downloaded-book"] {
            try await store.prepare(
                bookID: bookID,
                bookTitle: bookID == "downloaded-book" ? "Downloaded Book" : "Temporary Book",
                author: "Author",
                chapters: [.init(index: 0, title: "Chapter")]
            )
            let url = try await store.canonicalURL(bookID: bookID, chapterIndex: 0)
            try Data(repeating: 0xA1, count: 256).write(to: url)
            try await store.markAvailable(bookID: bookID, chapterIndex: 0)
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
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 0, title: "Chapter")]
        )
        let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: 0)
        try Data(repeating: 0xBA, count: 64).write(to: url)
        try await store.markAvailable(bookID: "book-id", chapterIndex: 0)

        let temporaryValues = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(temporaryValues.isExcludedFromBackup, true)

        try await store.promote(bookID: "book-id", chapterIndex: 0)
        let promoted = try await store.artifact(bookID: "book-id", chapterIndex: 0)
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

        let restoredStore = LocalAudioArtifactStore(root: root)
        _ = try await restoredStore.manifest(bookID: "book-id")
        refreshedURL.removeAllCachedResourceValues()
        let refreshedValues = try refreshedURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(refreshedValues.isExcludedFromBackup, false)
        #endif
    }
}
