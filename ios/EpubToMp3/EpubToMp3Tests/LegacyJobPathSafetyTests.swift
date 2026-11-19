// LegacyJobPathSafetyTests.swift
//
// Destructive legacy `Audiobooks/<jobId>` operations must never resolve to the
// Audiobooks root, a parent, a sibling or a symlink target. Every attack runs
// against real directories under a canonical temporary parent and checks that
// every planted sentinel, inside and outside the root, survives.

import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class LegacyJobPathSafetyTests: XCTestCase {
    private var parent: URL!
    private var root: URL!
    private var sentinels: [URL] = []

    /// Ids that must never address anything but a missing direct child.
    private static let attackIDs: [String] = [
        "", ".", "..", "../x", "a/b", "/abs", "\0", "abc\0", "..\0",
        String(repeating: "a", count: 300), "evil-job",
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyJobPathSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // Canonical path so /var and /private/var aliases cannot mask an escape.
        parent = URL(fileURLWithPath: try XCTUnwrap(temporary.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }), isDirectory: true)
        root = parent.appendingPathComponent("Audiobooks", isDirectory: true)
        AudiobookDownloadStorage.rootOverrideForTesting = root
        try plantSentinels()
    }

    override func tearDownWithError() throws {
        AudiobookDownloadStorage.rootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: parent)
        try super.tearDownWithError()
    }

    // MARK: Fixture

    private func write(_ relative: String, under base: URL, _ bytes: Data = Data([0x2A])) throws {
        let url = base.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        sentinels.append(url)
    }

    private func manifest(jobID: String, fileName: String) throws -> Data {
        try JSONEncoder().encode(AudiobookManifest(jobId: jobID, bookTitle: "Fixture",
            chapters: [.init(index: 0, title: "Chapter", mp3FileName: fileName, mp3Bytes: 1, downloadedAt: Date())],
            totalBytes: 1, completedAt: Date()))
    }

    private func plantSentinels() throws {
        // Outside the Audiobooks root.
        try write("outside.txt", under: parent)
        try write("fulltext.json", under: parent)
        try write("x/keep.txt", under: parent)
        try write("outside-dir/manifest.json", under: parent, manifest(jobID: "evil-job", fileName: "a.mp3"))
        try write("outside-dir/chapters/a.mp3", under: parent)
        try write("outside-dir/fulltext.json", under: parent)
        // Inside the root: the root's own files and other books' folders.
        try write("fulltext.json", under: root)
        try write("manifest.json", under: root, manifest(jobID: "", fileName: "keep.mp3"))
        try write("chapters/keep.mp3", under: root)
        try write("other-book/manifest.json", under: root, manifest(jobID: "other-book", fileName: "keep.mp3"))
        try write("other-book/chapters/keep.mp3", under: root)
        try write("other-book/fulltext.json", under: root)
        try write("a/b/keep.txt", under: root)
        try write("abs/keep.txt", under: root)
        try write("abc/keep.txt", under: root)
        // A job-shaped symlink that points outside the root.
        let link = root.appendingPathComponent("evil-job")
        try FileManager.default.createSymbolicLink(at: link,
            withDestinationURL: parent.appendingPathComponent("outside-dir", isDirectory: true))
        sentinels.append(link)
    }

    private func assertSentinelsIntact(_ id: String, _ operation: String, line: UInt = #line) {
        for url in sentinels {
            // attributesOfItem does not follow a final symlink, so the link itself is checked.
            let present = (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
            XCTAssertTrue(present, "\(operation)(\(id.debugDescription)) removed \(url.path)", line: line)
        }
    }

    private func resetFixture() throws {
        try? FileManager.default.removeItem(at: parent)
        sentinels.removeAll()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try plantSentinels()
    }

    // MARK: Attacks

    func testDeleteAudiobookRejectsUnsafeJobIDs() throws {
        for id in Self.attackIDs {
            try resetFixture()
            AudiobookDownloadStorage.deleteAudiobook(jobId: id)
            assertSentinelsIntact(id, "deleteAudiobook")
        }
    }

    func testDeleteChapterRejectsUnsafeJobIDs() throws {
        for id in Self.attackIDs {
            try resetFixture()
            let outsideManifest = try Data(contentsOf: parent.appendingPathComponent("outside-dir/manifest.json"))
            AudiobookDownloadStorage.deleteChapter(jobId: id, chapterIndex: 0)
            assertSentinelsIntact(id, "deleteChapter")
            XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("outside-dir/manifest.json")),
                           outsideManifest, "deleteChapter(\(id.debugDescription)) rewrote an outside manifest")
        }
    }

    func testDeleteChapterRejectsManifestFileNameThatEscapesTheJobFolder() throws {
        try write("tampered/manifest.json", under: root, manifest(jobID: "tampered", fileName: "../../../outside.txt"))
        // The traversal needs a real chapters/ directory to walk back out of.
        try write("tampered/chapters/keep.mp3", under: root)
        AudiobookDownloadStorage.deleteChapter(jobId: "tampered", chapterIndex: 0)
        assertSentinelsIntact("tampered", "deleteChapter")
    }

    func testFulltextEvictRejectsUnsafeJobIDs() throws {
        for id in Self.attackIDs {
            try resetFixture()
            XCTAssertFalse(FulltextStore.evict(jobId: id), "evict(\(id.debugDescription)) reported a removal")
            assertSentinelsIntact(id, "FulltextStore.evict")
        }
    }

    func testReadsDoNotFollowUnsafeJobIDs() throws {
        for id in Self.attackIDs {
            try resetFixture()
            XCTAssertEqual(AudiobookDownloadStorage.locallyDownloadedIndices(for: id), [], id.debugDescription)
            XCTAssertNil(AudiobookDownloadStorage.loadManifest(for: id), id.debugDescription)
            XCTAssertNil(AudiobookDownloadStorage.localAudioURL(jobId: id, chapterIndex: 0), id.debugDescription)
            XCTAssertNil(FulltextStore.loadFromDisk(jobId: id), id.debugDescription)
            assertSentinelsIntact(id, "read")
        }
    }

    #if !APP_FOUNDATION_HOST_TESTS
    func testTouchLastAccessDoesNotWriteThroughUnsafeJobIDs() throws {
        for id in Self.attackIDs {
            try resetFixture()
            AudiobookCacheEviction.touchLastAccess(jobId: id)
            for escaped in [parent.appendingPathComponent("last_access"),
                            root.appendingPathComponent("last_access"),
                            parent.appendingPathComponent("outside-dir/last_access")] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path),
                               "touchLastAccess(\(id.debugDescription)) wrote \(escaped.path)")
            }
        }
    }
    #endif

    // MARK: Valid ids keep working

    func testValidJobIDsDeleteExactlyTheirOwnFolder() throws {
        for id in ["3F2504E0-4F89-11D3-9A0C-0305E82C3301", "embedded-0123abcd", "job_1.v2", "fixture"] {
            try resetFixture()
            try write("\(id)/manifest.json", under: root, manifest(jobID: id, fileName: "a.mp3"))
            try write("\(id)/chapters/a.mp3", under: root)
            try write("\(id)/fulltext.json", under: root)
            let own = sentinels.suffix(3)
            sentinels.removeLast(3)

            XCTAssertEqual(AudiobookDownloadStorage.locallyDownloadedIndices(for: id), [0])
            XCTAssertTrue(FulltextStore.evict(jobId: id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: own.last!.path))
            AudiobookDownloadStorage.deleteChapter(jobId: id, chapterIndex: 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(id)/chapters/a.mp3").path))
            XCTAssertEqual(AudiobookDownloadStorage.loadManifest(for: id)?.chapters, [])
            AudiobookDownloadStorage.deleteAudiobook(jobId: id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id).path))
            assertSentinelsIntact(id, "valid removal")
        }
    }
}
