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

    /// Seeds one book whose chapters are persisted, playable temporary audio.
    @discardableResult
    func seedAvailable(
        bookID: String = "book-id", title: String = "Book", author: String? = nil,
        chapters: [(Int, String)], bytes: Data
    ) throws -> [Int: URL] {
        try LocalAudioArtifactFixture.seed(
            root: root, bookID: bookID, bookTitle: title, author: author,
            chapters: chapters.map { .init(index: $0.0, title: $0.1, audio: bytes) })
    }

    func artifact(_ bookID: String = "book-id", _ index: Int) throws -> LocalAudioArtifactStore.ChapterArtifact? {
        try LocalAudioArtifactFixture.artifact(root: root, bookID: bookID, chapterIndex: index)
    }

    func assertExplicitRemovalClearsPlaybackRetention(removeWholeBook: Bool) async throws {
        let store = LocalAudioArtifactStore(root: root)
        let bytes = Data(repeating: 0xA7, count: 128)
        for bookID in ["removed-book", "untouched-book"] {
            try seedAvailable(bookID: bookID, title: bookID, chapters: [(0, "First"), (1, "Second")], bytes: bytes)
            for index in [0, 1] {
                // Audible playback records durable intent and promotes playable audio.
                try await store.requestPlaybackRetention(bookID: bookID, chapterIndex: index)
                let artifact = try self.artifact(bookID, index)
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
            let removed = try artifact("removed-book", index)
            XCTAssertEqual(removed?.state, .pending)
            XCTAssertEqual(removed?.retention, .temporary)
            XCTAssertNotEqual(removed?.playbackRetentionRequested, true,
                              "Explicit removal must persist cancellation of the previous listening intent.")
        }
        for index in removedIndices {
            // Audio that reappears on disk keeps the persisted removal: reading
            // the store must not restore the removed download by itself.
            var regenerated = try XCTUnwrap(try artifact("removed-book", index))
            let url = try XCTUnwrap(try LocalAudioArtifactFixture.seed(root: root, bookID: "removed-book", chapters: [
                .init(index: index, title: regenerated.title, audio: bytes,
                      playbackRetentionRequested: regenerated.playbackRetentionRequested)
            ])[index])
            _ = try await reopenedStore.playableSnapshot(bookID: "removed-book", engine: "e", voice: "v", language: nil)
            regenerated = try XCTUnwrap(try artifact("removed-book", index))
            XCTAssertEqual(regenerated.retention, .temporary,
                           "Regeneration without a new listening request must not restore a removed download.")
            XCTAssertNotEqual(regenerated.playbackRetentionRequested, true)

            try await reopenedStore.requestPlaybackRetention(bookID: "removed-book", chapterIndex: index)
            let requestedAgain = try artifact("removed-book", index)
            XCTAssertEqual(requestedAgain?.retention, .downloaded)
            XCTAssertEqual(requestedAgain?.playbackRetentionRequested, true)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }

        let untouched = removeWholeBook
            ? [("untouched-book", 0), ("untouched-book", 1)]
            : [("removed-book", 1), ("untouched-book", 0), ("untouched-book", 1)]
        for (bookID, index) in untouched {
            let artifact = try self.artifact(bookID, index)
            let url = try await reopenedStore.canonicalURL(bookID: bookID, chapterIndex: index)
            XCTAssertEqual(artifact?.state, .available)
            XCTAssertEqual(artifact?.retention, .downloaded)
            XCTAssertEqual(artifact?.playbackRetentionRequested, true)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
}
