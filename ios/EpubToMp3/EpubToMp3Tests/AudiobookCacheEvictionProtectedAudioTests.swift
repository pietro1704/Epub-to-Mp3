// AudiobookCacheEvictionTests.swift
//
// Unit tests for `AudiobookCacheEviction`.
//
// All tests run entirely on a temporary directory that replaces the real
// app-owned audiobook root via the explicit `root:` eviction helpers
// — but since `audiobooksRoot()` is a nonisolated static that calls
// FileManager directly, we instead build synthetic on-disk fixtures inside
// a temp folder and call the internal scan/eviction helpers through the
// public API that accepts explicit entries.
//
// The public API under test:
//   - `scanEntries()`      — reads real folders/manifests
//   - `runEviction(...)`   — pure LRU+TTL logic driven by scanEntries
//   - `touchLastAccess(jobId:)` / `readLastAccess(for:)` via sidecar file
//   - `totalCachedBytes()` — sum from manifests
//   - `deleteAudiobook(jobId:)` — best-effort removal

import XCTest

@testable import EpubToMp3

extension AudiobookCacheEvictionTests {
    func testStorageUsageBudgetFractionIsClamped() {
        XCTAssertEqual(
            StorageUsageSnapshot(offlineAudioBytes: 3, ttsCacheBytes: 2, totalBytes: 5, budgetBytes: 10).budgetFraction,
            0.5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StorageUsageSnapshot(offlineAudioBytes: 20, ttsCacheBytes: 0, totalBytes: 20, budgetBytes: 10).budgetFraction,
            1.0,
            accuracy: 0.001
        )
    }

    func testLocallyDownloadedIndicesVerifiesFilesOnDisk() throws {
        let jobId = "test-local-\(UUID().uuidString)"
        defer { AudiobookCacheEviction.deleteAudiobook(jobId: jobId) }
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

    func testStaleOfflineBookIdsFlagsEvictedAndUnlinkedBooks() throws {
        let liveJobId = "test-stale-\(UUID().uuidString)"
        defer { AudiobookCacheEviction.deleteAudiobook(jobId: liveJobId) }
        try plantRealAudiobook(jobId: liveJobId, entries: [
            (index: 0, fileName: "a.mp3", onDisk: true)
        ])

        let books = [
            makeBook(id: "kept", lastJobId: liveJobId, cachedOffline: true),
            makeBook(id: "evicted", lastJobId: "test-gone-\(UUID().uuidString)", cachedOffline: true),
            makeBook(id: "never-linked", lastJobId: nil, cachedOffline: true),
            makeBook(id: "not-offline", lastJobId: nil, cachedOffline: false)
        ]
        XCTAssertEqual(
            AudiobookCacheEviction.staleOfflineBookIds(books: books),
            ["evicted", "never-linked"]
        )
    }

    func testStaleOfflineBookIdsFlagsMissingChapterFileAndIncompleteManifest() throws {
        let missingFileJobId = "test-missing-file-\(UUID().uuidString)"
        let incompleteJobId = "test-incomplete-\(UUID().uuidString)"
        defer {
            AudiobookCacheEviction.deleteAudiobook(jobId: missingFileJobId)
            AudiobookCacheEviction.deleteAudiobook(jobId: incompleteJobId)
        }

        try plantRealAudiobook(jobId: missingFileJobId, entries: [
            (index: 0, fileName: "present.mp3", onDisk: true),
            (index: 1, fileName: "missing.mp3", onDisk: false)
        ])
        try plantRealAudiobook(jobId: incompleteJobId, entries: [
            (index: 0, fileName: "partial.mp3", onDisk: true)
        ])
        guard var missingManifest = AudiobookDownloadStorage.loadManifest(for: missingFileJobId),
              var incompleteManifest = AudiobookDownloadStorage.loadManifest(for: incompleteJobId) else {
            XCTFail("Fixtures must have manifests")
            return
        }
        missingManifest.completedAt = Date()
        incompleteManifest.completedAt = nil
        try AudiobookDownloadStorage.saveManifest(missingManifest)
        try AudiobookDownloadStorage.saveManifest(incompleteManifest)

        let books = [
            makeBook(id: "missing-file", lastJobId: missingFileJobId, cachedOffline: true),
            makeBook(id: "incomplete", lastJobId: incompleteJobId, cachedOffline: true)
        ]

        XCTAssertEqual(
            AudiobookCacheEviction.staleOfflineBookIds(books: books),
            ["missing-file", "incomplete"]
        )
    }

    func testProductionPassNeverEvictsLegacyOfflineAudio() throws {
        let activeJobId = "active-registry-\(UUID().uuidString)"
        let expiredJobId = "expired-registry-\(UUID().uuidString)"
        let oldDate = Date().addingTimeInterval(-48 * 3600)
        defer {
            CacheActivityRegistry.end(jobId: activeJobId)
        }

        try plantAudiobook(
            jobId: activeJobId,
            totalBytes: 128,
            downloadedAt: oldDate,
            lastAccessedAt: oldDate
        )
        try plantAudiobook(
            jobId: expiredJobId,
            totalBytes: 128,
            downloadedAt: oldDate,
            lastAccessedAt: oldDate
        )

        CacheActivityRegistry.begin(jobId: activeJobId)
        let evicted = AudiobookCacheEviction.runEviction(
            root: tempRoot,
            budgetBytes: Int64.max,
            ttlSeconds: 24 * 3600
        )

        XCTAssertFalse(evicted.contains(activeJobId), "An actively opened/synthesised job must be protected")
        XCTAssertFalse(evicted.contains(expiredJobId), "Legacy audio is protected until the listener removes it")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent(activeJobId, isDirectory: true).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent(expiredJobId, isDirectory: true).path
        ))
    }
}
