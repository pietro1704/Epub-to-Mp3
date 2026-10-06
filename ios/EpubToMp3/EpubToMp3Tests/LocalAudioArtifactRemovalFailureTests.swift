import Foundation
import XCTest
@testable import EpubToMp3

#if os(macOS)
final class LocalAudioArtifactRemovalFailureTests: XCTestCase {
    private func fixture() async throws -> (URL, LocalAudioArtifactStore, URL, String, Data) {
        let bookID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemovalFailure-\(bookID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LocalAudioArtifactStore(root: root)
        try await store.prepare(bookID: bookID, bookTitle: "Removal fixture", author: nil,
                                chapters: [.init(index: 0, title: "Chapter")])
        let canonical = try await store.canonicalURL(bookID: bookID, chapterIndex: 0)
        let bytes = Data([0x49, 0x44, 0x33, 0x04, 0x01, 0x02, 0x03])
        try bytes.write(to: canonical)
        try await store.markAvailable(bookID: bookID, chapterIndex: 0)
        try await store.requestPlaybackRetention(bookID: bookID, chapterIndex: 0)
        return (root, store, canonical, bookID, bytes)
    }

    func testFilesystemDeletionFailurePreservesDownloadedArtifactAndReportsError() async throws {
        let (root, store, canonical, bookID, bytes) = try await fixture()
        let beforeValue = try await store.artifact(bookID: bookID, chapterIndex: 0)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertEqual(before.retention, .downloaded)
        XCTAssertEqual(before.playbackRetentionRequested, true)
        let parent = canonical.deletingLastPathComponent()
        let probe = parent.appendingPathComponent("permission-probe.bin")
        try Data([1]).write(to: probe)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        }
        // The sibling probe proves this filesystem denies unlink, rather
        // than assuming mode bits enforce permissions for the test process.
        do {
            try FileManager.default.removeItem(at: probe)
            XCTFail("The permission fixture must reject sibling deletion")
            return
        } catch {
            let error = error as NSError
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, NSFileWriteNoPermissionError)
        }
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: parent.deletingLastPathComponent().path),
                      "Manifest persistence must remain writable during the failed audio deletion")
        do {
            try await store.removeDownloadedAudio(bookID: bookID, chapterIndex: 0)
            XCTFail("A denied audio deletion must not report success")
        } catch {
            let error = error as NSError
            XCTAssertEqual(error.domain, NSCocoaErrorDomain)
            XCTAssertEqual(error.code, NSFileWriteNoPermissionError)
        }
        XCTAssertEqual(try Data(contentsOf: canonical), bytes)
        let reopened = LocalAudioArtifactStore(root: root)
        let after = try await reopened.artifact(bookID: bookID, chapterIndex: 0)
        XCTAssertEqual(after?.state, before.state)
        XCTAssertEqual(after?.retention, before.retention)
        XCTAssertEqual(after?.byteCount, before.byteCount)
        XCTAssertEqual(after?.playbackRetentionRequested, before.playbackRetentionRequested)
    }

    func testAlreadyMissingCanonicalAudioCanStillClearDownloadedMetadata() async throws {
        let (root, store, canonical, bookID, _) = try await fixture()
        try FileManager.default.removeItem(at: canonical)
        try await store.removeDownloadedAudio(bookID: bookID, chapterIndex: 0)
        let reopened = LocalAudioArtifactStore(root: root)
        let artifact = try await reopened.artifact(bookID: bookID, chapterIndex: 0)
        XCTAssertEqual(artifact?.state, .pending)
        XCTAssertEqual(artifact?.retention, .temporary)
        XCTAssertEqual(artifact?.byteCount, 0)
        XCTAssertNotEqual(artifact?.playbackRetentionRequested, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
    }
}
#endif
