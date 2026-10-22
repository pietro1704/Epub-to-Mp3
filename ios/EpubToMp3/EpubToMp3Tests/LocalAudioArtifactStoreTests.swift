import Foundation
import XCTest
@testable import EpubToMp3

final class LocalAudioArtifactStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-audio-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }




    func assertExplicitRemovalClearsPlaybackRetention(removeWholeBook: Bool) async throws {
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



















}
