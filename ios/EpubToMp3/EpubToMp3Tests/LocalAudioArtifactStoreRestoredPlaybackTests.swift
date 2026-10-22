import Foundation
import XCTest

@testable import EpubToMp3

extension LocalAudioArtifactStoreTests {
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
}
