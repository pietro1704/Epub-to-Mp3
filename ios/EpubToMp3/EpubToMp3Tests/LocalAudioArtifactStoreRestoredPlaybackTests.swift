import Foundation
import XCTest

@testable import EpubToMp3

extension LocalAudioArtifactStoreTests {
    func testNewStoreInstanceRestoresTheCanonicalAvailableArtifact() async throws {
        let expectedURL = try XCTUnwrap(
            try seedAvailable(chapters: [(7, "Seven")], bytes: Data(repeating: 0x33, count: 64))[7])

        let restoredStore = LocalAudioArtifactStore(root: root)
        let snapshot = try await restoredStore.playableSnapshot(
            bookID: "book-id", engine: "edge", voice: "voice", language: "en")
        guard let restored = try artifact(7) else {
            return XCTFail("A persisted artifact must survive a process restart.")
        }

        let restoredURL = try await restoredStore.canonicalURL(bookID: "book-id", chapterIndex: 7)
        XCTAssertEqual(restored.state, .available)
        XCTAssertEqual(restoredURL, expectedURL)
        XCTAssertEqual(snapshot?.playableChapters.map(\.index), [7])
        XCTAssertEqual(snapshot?.playableChapters.first?.downloadUrl, expectedURL.absoluteString)
    }

    func testCompleteManifestRecreatesAFinishedPlayableSnapshot() async throws {
        try seedAvailable(author: "Author", chapters: [(0, "First"), (1, "Second")],
                          bytes: Data(repeating: 0xD1, count: 32))

        let store = LocalAudioArtifactStore(root: root)
        guard let snapshot = try await store.playableSnapshot(
            bookID: "book-id",
            engine: "edge",
            voice: "voice",
            language: "en"
        ) else {
            return XCTFail("A complete manifest must produce a player-compatible snapshot.")
        }

        XCTAssertEqual(snapshot.state, "finished")
        XCTAssertEqual(snapshot.jobId, "embedded-book-id")
        XCTAssertEqual(snapshot.bookTitle, "Book")
        XCTAssertEqual(snapshot.chaptersCompleted, 2)
        XCTAssertEqual(snapshot.playableChapters.map(\.displayTitle), ["First", "Second"])
    }

    func testPlayableSnapshotRestoresLocalChaptersBeforeTheBookIsComplete() async throws {
        try LocalAudioArtifactFixture.seed(root: root, bookID: "book-id", bookTitle: "Book", author: "Author", chapters: [
            .init(index: 0, title: "First", audio: Data(repeating: 0xD1, count: 32)),
            .init(index: 1, title: "Second", state: .pending)
        ])

        let store = LocalAudioArtifactStore(root: root)
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
}
