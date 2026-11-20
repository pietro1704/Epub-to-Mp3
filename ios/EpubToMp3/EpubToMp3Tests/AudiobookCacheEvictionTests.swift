// AudiobookCacheEvictionTests.swift
//
// Unit tests for reading the previous audiobook-folder layout:
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
        try LegacyAudiobookFixture.save(AudiobookManifest(
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
}
