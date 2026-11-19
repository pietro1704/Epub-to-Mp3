import Foundation
import XCTest

@testable import EpubToMp3

extension LocalAudioArtifactStoreTests {
    func testAvailableArtifactWhoseFileWasRemovedIsNeitherPlayedNorPromoted() async throws {
        let url = try XCTUnwrap(
            try seedAvailable(chapters: [(0, "Chapter")], bytes: Data(repeating: 0xEE, count: 32))[0])
        try FileManager.default.removeItem(at: url)

        let store = LocalAudioArtifactStore(root: root)
        let snapshot = try await store.playableSnapshot(
            bookID: "book-id", engine: "edge", voice: "voice", language: nil)
        try await store.requestPlaybackRetention(bookID: "book-id", chapterIndex: 0)

        XCTAssertNil(snapshot, "A manifest entry without its audio file is not playable.")
        let artifact = try self.artifact(0)
        XCTAssertEqual(artifact?.retention, .temporary, "Missing audio must not become a protected download.")
        XCTAssertEqual(artifact?.playbackRetentionRequested, true)
        let downloadedBooks = try await store.downloadedBooks()
        XCTAssertEqual(downloadedBooks, [])
    }

    func testStoreWritesPreservePersistedFailureDetailsOfOtherChapters() async throws {
        try LocalAudioArtifactFixture.seed(root: root, bookID: "book-id", bookTitle: "Book", chapters: [
            .init(index: 0, title: "Generating", state: .generating),
            .init(index: 1, title: "Waiting", state: .waitingForWiFi),
            .init(index: 2, title: "Failed", state: .failed, retryCount: 1, lastError: "Network unavailable"),
            .init(index: 3, title: "Available", audio: Data(repeating: 0xC0, count: 32))
        ])

        let store = LocalAudioArtifactStore(root: root)
        let snapshot = try await store.playableSnapshot(
            bookID: "book-id", engine: "edge", voice: "voice", language: nil)
        // Promotion rewrites the manifest; other chapters keep their state.
        try await store.requestPlaybackRetention(bookID: "book-id", chapterIndex: 3)

        XCTAssertEqual(snapshot?.playableChapters.map(\.index), [3])
        XCTAssertEqual(snapshot?.state, "partial")
        XCTAssertEqual(try artifact(0)?.state, .generating)
        XCTAssertEqual(try artifact(1)?.state, .waitingForWiFi)
        let failed = try artifact(2)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.retryCount, 1)
        XCTAssertEqual(failed?.lastError, "Network unavailable")
        let available = try artifact(3)
        XCTAssertEqual(available?.state, .available)
        XCTAssertEqual(available?.retention, .downloaded)
        XCTAssertNil(available?.lastError)
    }

    func testCanonicalURLStaysInsideTheStoreForUnsafeBookIdentifiers() async throws {
        let store = LocalAudioArtifactStore(root: root)
        let bookID = "../Book / with symbols"
        try LocalAudioArtifactFixture.seed(root: root, bookID: bookID, bookTitle: "Book",
                                           chapters: [.init(index: 3, title: "Chapter", state: .pending)])

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
            let retained = try XCTUnwrap(try LocalAudioArtifactFixture.seed(
                root: storage, bookID: "retained-book", bookTitle: "Retained",
                chapters: [.init(index: 0, title: "Retained chapter", audio: retainedBytes)])[0])

            try LocalAudioArtifactFixture.seed(
                root: storage, bookID: bookID, bookTitle: "Unsafe identity",
                chapters: [.init(index: 1, title: "Disposable chapter", audio: Data(repeating: 0xB6, count: 32))])
            let audio = try await store.canonicalURL(bookID: bookID, chapterIndex: 1)
            let bookDirectory = audio.deletingLastPathComponent().deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
            let canonicalStorage = storage.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertTrue(bookDirectory.path.hasPrefix(canonicalStorage.path + "/"), bookID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), bookID)
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
        try LocalAudioArtifactFixture.seed(root: root, bookID: bookID, bookTitle: "Book",
                                           chapters: [.init(index: 2, title: "Chapter", state: .pending)])
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
