import Foundation
import XCTest
@testable import EpubToMp3

final class LocalAudioArtifactStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-audio-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testClassifiesCocoaOutOfSpaceAsStoragePressure() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteOutOfSpaceError
        )

        XCTAssertTrue(StoragePressureError.isInsufficientSpace(error))
    }

    func testRemovingDownloadedChapterClearsPlaybackRetentionAcrossRegeneration() async throws {
        try await assertExplicitRemovalClearsPlaybackRetention(removeWholeBook: false)
    }

    func testClearingDownloadedBookClearsPlaybackRetentionAcrossRegeneration() async throws {
        try await assertExplicitRemovalClearsPlaybackRetention(removeWholeBook: true)
    }

    private func assertExplicitRemovalClearsPlaybackRetention(removeWholeBook: Bool) async throws {
        let store = LocalAudioArtifactStore(root: root)
        let chapters: [LocalAudioArtifactStore.ChapterSeed] = [
            .init(index: 0, title: "First"), .init(index: 1, title: "Second")
        ]
        let bytes = Data(repeating: 0xA7, count: 128)
        for bookID in ["removed-book", "untouched-book"] {
            try await store.prepare(bookID: bookID, bookTitle: bookID, author: nil, chapters: chapters)
            for index in [0, 1] {
                // Audible playback can request durable retention before the final file exists.
                try await store.requestPlaybackRetention(bookID: bookID, chapterIndex: index)
                let url = try await store.canonicalURL(bookID: bookID, chapterIndex: index)
                try bytes.write(to: url)
                try await store.markAvailable(bookID: bookID, chapterIndex: index)
                let artifact = try await store.artifact(bookID: bookID, chapterIndex: index)
                XCTAssertEqual(artifact?.retention, .downloaded)
                XCTAssertEqual(artifact?.playbackRetentionRequested, true)
            }
        }

        if removeWholeBook {
            try await store.clearDownloadedAudio(bookID: "removed-book")
        } else {
            try await store.removeDownloadedAudio(bookID: "removed-book", chapterIndex: 0)
        }

        let reopenedStore = LocalAudioArtifactStore(root: root)
        let removedIndices = removeWholeBook ? [0, 1] : [0]
        for index in removedIndices {
            let url = try await reopenedStore.canonicalURL(bookID: "removed-book", chapterIndex: index)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let removed = try await reopenedStore.artifact(bookID: "removed-book", chapterIndex: index)
            XCTAssertEqual(removed?.state, .pending)
            XCTAssertEqual(removed?.retention, .temporary)
            XCTAssertNotEqual(removed?.playbackRetentionRequested, true,
                              "Explicit removal must persist cancellation of the previous listening intent.")
        }
        try await reopenedStore.prepare(
            bookID: "removed-book", bookTitle: "Removed book", author: nil, chapters: chapters)
        for index in removedIndices {
            let url = try await reopenedStore.canonicalURL(bookID: "removed-book", chapterIndex: index)
            try bytes.write(to: url)
            try await reopenedStore.markAvailable(bookID: "removed-book", chapterIndex: index)
            let regenerated = try await reopenedStore.artifact(bookID: "removed-book", chapterIndex: index)
            XCTAssertEqual(regenerated?.retention, .temporary,
                           "Regeneration without a new listening request must not restore a removed download.")
            XCTAssertNotEqual(regenerated?.playbackRetentionRequested, true)

            try await reopenedStore.requestPlaybackRetention(bookID: "removed-book", chapterIndex: index)
            let requestedAgain = try await reopenedStore.artifact(bookID: "removed-book", chapterIndex: index)
            XCTAssertEqual(requestedAgain?.retention, .downloaded)
            XCTAssertEqual(requestedAgain?.playbackRetentionRequested, true)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }

        let untouched = removeWholeBook
            ? [("untouched-book", 0), ("untouched-book", 1)]
            : [("removed-book", 1), ("untouched-book", 0), ("untouched-book", 1)]
        for (bookID, index) in untouched {
            let artifact = try await reopenedStore.artifact(bookID: bookID, chapterIndex: index)
            let url = try await reopenedStore.canonicalURL(bookID: bookID, chapterIndex: index)
            XCTAssertEqual(artifact?.state, .available)
            XCTAssertEqual(artifact?.retention, .downloaded)
            XCTAssertEqual(artifact?.playbackRetentionRequested, true)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testDoesNotClassifyAnUnrelatedErrorAsStoragePressure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        XCTAssertFalse(StoragePressureError.isInsufficientSpace(error))
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

    func testNewStoreInstanceRestoresTheCanonicalAvailableArtifact() async throws {
        let firstStore = LocalAudioArtifactStore(root: root)
        try await firstStore.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: nil,
            chapters: [.init(index: 7, title: "Seven")]
        )
        let expectedURL = try await firstStore.canonicalURL(bookID: "book-id", chapterIndex: 7)
        try Data(repeating: 0x33, count: 64).write(to: expectedURL)
        try await firstStore.markAvailable(bookID: "book-id", chapterIndex: 7)

        let restoredStore = LocalAudioArtifactStore(root: root)
        guard let restored = try await restoredStore.artifact(bookID: "book-id", chapterIndex: 7) else {
            return XCTFail("A persisted artifact must survive a process restart.")
        }

        let restoredURL = try await restoredStore.canonicalURL(bookID: "book-id", chapterIndex: 7)
        XCTAssertEqual(restored.state, .available)
        XCTAssertEqual(restoredURL, expectedURL)
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

        let usage = LocalAudioArtifactStore.storageUsage(root: root)
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

    func testCompletedSnapshotIsRecreatedFromTheManifest() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: "Author",
            chapters: [.init(index: 0, title: "First"), .init(index: 1, title: "Second")]
        )
        for index in [0, 1] {
            let url = try await store.canonicalURL(bookID: "book-id", chapterIndex: index)
            try Data(repeating: 0xD1, count: 32).write(to: url)
            try await store.markAvailable(bookID: "book-id", chapterIndex: index)
        }

        guard let snapshot = try await store.completedSnapshot(
            bookID: "book-id",
            engine: "edge",
            voice: "voice",
            language: "en"
        ) else {
            return XCTFail("A complete manifest must produce a player-compatible snapshot.")
        }

        XCTAssertEqual(snapshot.jobId, "embedded-book-id")
        XCTAssertEqual(snapshot.bookTitle, "Book")
        XCTAssertEqual(snapshot.chaptersCompleted, 2)
        XCTAssertEqual(snapshot.playableChapters.map(\.displayTitle), ["First", "Second"])
    }

    func testPlayableSnapshotRestoresLocalChaptersBeforeTheBookIsComplete() async throws {
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(
            bookID: "book-id",
            bookTitle: "Book",
            author: "Author",
            chapters: [.init(index: 0, title: "First"), .init(index: 1, title: "Second")]
        )
        let firstURL = try await store.canonicalURL(bookID: "book-id", chapterIndex: 0)
        try Data(repeating: 0xD1, count: 32).write(to: firstURL)
        try await store.markAvailable(bookID: "book-id", chapterIndex: 0)

        let snapshot = try await store.playableSnapshot(
            bookID: "book-id",
            engine: "edge",
            voice: "voice",
            language: "en"
        )

        XCTAssertEqual(snapshot?.state, "partial")
        XCTAssertEqual(snapshot?.chaptersTotal, 2)
        XCTAssertEqual(snapshot?.chaptersCompleted, 1)
        XCTAssertEqual(snapshot?.playableChapters.map(\.index), [0])
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
