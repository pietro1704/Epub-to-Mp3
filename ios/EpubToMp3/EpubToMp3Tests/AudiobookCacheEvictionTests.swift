// AudiobookCacheEvictionTests.swift
//
// Unit tests for the retained legacy audiobook-folder bookkeeping:
//   - `AudiobookCacheEviction.touchLastAccess(jobId:)` sidecar writes
//   - `AudiobookDownloadStorage.locallyDownloadedIndices(for:)` disk truth
//
// Every test runs on a temporary root installed through
// `AudiobookDownloadStorage.rootOverrideForTesting`, so no test touches the
// user's live Documents directory.

import XCTest
@testable import EpubToMp3

final class AudiobookCacheEvictionTests: XCTestCase {
    var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheEvictionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        AudiobookDownloadStorage.rootOverrideForTesting = tempRoot
    }

    override func tearDownWithError() throws {
        AudiobookDownloadStorage.rootOverrideForTesting = nil
        try? FileManager.default.removeItem(at: tempRoot)
        try super.tearDownWithError()
    }

    private func plantRealAudiobook(
        jobId: String, entries: [(index: Int, fileName: String, onDisk: Bool)]
    ) throws {
        let folder = try XCTUnwrap(AudiobookDownloadStorage.audiobookFolder(for: jobId))
        var chapters: [AudiobookManifest.ChapterEntry] = []
        for entry in entries {
            if entry.onDisk {
                try Data(repeating: 0xFF, count: 128)
                    .write(to: folder.appendingPathComponent(entry.fileName))
            }
            chapters.append(AudiobookManifest.ChapterEntry(
                index: entry.index, title: "ch\(entry.index)",
                mp3FileName: entry.fileName, mp3Bytes: 128, downloadedAt: Date()
            ))
        }
        try AudiobookDownloadStorage.saveManifest(AudiobookManifest(
            jobId: jobId, bookTitle: jobId, chapters: chapters,
            totalBytes: Int64(entries.count * 128), completedAt: Date()
        ))
    }

    func testLocallyDownloadedIndicesVerifiesFilesOnDisk() throws {
        let jobId = "test-local-\(UUID().uuidString)"
        defer { AudiobookDownloadStorage.deleteAudiobook(jobId: jobId) }
        try plantRealAudiobook(jobId: jobId, entries: [
            (index: 0, fileName: "a.mp3", onDisk: true),
            (index: 2, fileName: "b.mp3", onDisk: true),
            (index: 5, fileName: "gone.mp3", onDisk: false) // manifest says yes, disk says no
        ])
        XCTAssertEqual(AudiobookDownloadStorage.locallyDownloadedIndices(for: jobId), [0, 2])
    }

    func testLocallyDownloadedIndicesEmptyWithoutManifest() {
        XCTAssertEqual(
            AudiobookDownloadStorage.locallyDownloadedIndices(for: "test-missing-\(UUID().uuidString)"),
            []
        )
    }

    func testTouchLastAccessWritesSidecar() throws {
        let jobId = "touchtest-\(UUID().uuidString.prefix(6))"
        let folder = AudiobookDownloadStorage.audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // ISO8601DateFormatter truncates to whole seconds, so `parsed` may be
        // up to 1 second before `before`. Allow a 1-second window on the lower bound.
        let before = Date().addingTimeInterval(-1)
        AudiobookCacheEviction.touchLastAccess(jobId: jobId)
        let after = Date()

        let sidecar = folder.appendingPathComponent("last_access")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path),
                      "touchLastAccess must create a last_access sidecar file")
        let raw = try String(contentsOf: sidecar, encoding: .utf8)
        let parsed = ISO8601DateFormatter().date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertNotNil(parsed)
        XCTAssertGreaterThanOrEqual(parsed!, before, "timestamp must be within 1s of call time")
        XCTAssertLessThanOrEqual(parsed!, after.addingTimeInterval(1))
    }
}
