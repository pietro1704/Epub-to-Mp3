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
    func testUnderBudgetNoEviction() throws {
        let now = Date()
        try plantAudiobook(jobId: "book1", totalBytes: 100_000, downloadedAt: now.addingTimeInterval(-3600))
        try plantAudiobook(jobId: "book2", totalBytes: 200_000, downloadedAt: now.addingTimeInterval(-1800))

        // Budget is 1 MB — well above 300 KB total.
        let evicted = runTestEviction(budgetBytes: 1_000_000, ttlSeconds: 48 * 3600)

        XCTAssertTrue(evicted.isEmpty, "Under budget and within TTL — nothing should be evicted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("book1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("book2").path))
    }

    func testTTLEvictsOldEntries() throws {
        let now = Date()
        // book1 is 48 h old — over default 24 h TTL.
        try plantAudiobook(
            jobId: "book1",
            totalBytes: 100_000,
            downloadedAt: now.addingTimeInterval(-48 * 3600),
            lastAccessedAt: now.addingTimeInterval(-48 * 3600)
        )
        // book2 is fresh.
        try plantAudiobook(
            jobId: "book2",
            totalBytes: 100_000,
            downloadedAt: now.addingTimeInterval(-1800),
            lastAccessedAt: now.addingTimeInterval(-1800)
        )

        let evicted = runTestEviction(budgetBytes: 10_000_000, ttlSeconds: 24 * 3600)

        XCTAssertEqual(evicted, ["book1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("book1").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("book2").path))
    }

    func testBudgetEvictsLRUFirst() throws {
        let now = Date()
        // oldest access = book_a, then book_b, then book_c (freshest).
        try plantAudiobook(
            jobId: "book_a",
            totalBytes: 400_000,
            downloadedAt: now.addingTimeInterval(-7200),
            lastAccessedAt: now.addingTimeInterval(-7200)
        )
        try plantAudiobook(
            jobId: "book_b",
            totalBytes: 400_000,
            downloadedAt: now.addingTimeInterval(-3600),
            lastAccessedAt: now.addingTimeInterval(-3600)
        )
        try plantAudiobook(
            jobId: "book_c",
            totalBytes: 400_000,
            downloadedAt: now.addingTimeInterval(-900),
            lastAccessedAt: now.addingTimeInterval(-900)
        )
        // Total = 1.2 MB; budget = 800 KB — must evict the oldest (book_a).
        let evicted = runTestEviction(budgetBytes: 800_000, ttlSeconds: 48 * 3600)

        XCTAssertTrue(evicted.contains("book_a"), "LRU eviction must remove oldest-accessed first")
        XCTAssertFalse(evicted.contains("book_c"), "Freshest entry must be kept")
    }

    func testActiveJobIdIsNeverEvicted() throws {
        let now = Date()
        // Both books are over TTL, but book1 is actively playing.
        try plantAudiobook(
            jobId: "book1",
            totalBytes: 50_000,
            downloadedAt: now.addingTimeInterval(-50 * 3600),
            lastAccessedAt: now.addingTimeInterval(-50 * 3600)
        )
        try plantAudiobook(
            jobId: "book2",
            totalBytes: 50_000,
            downloadedAt: now.addingTimeInterval(-50 * 3600),
            lastAccessedAt: now.addingTimeInterval(-50 * 3600)
        )

        let evicted = runTestEviction(
            budgetBytes: 10_000_000,
            ttlSeconds: 24 * 3600,
            activeJobIds: ["book1"]
        )

        XCTAssertFalse(evicted.contains("book1"), "Active playback job must never be evicted")
        XCTAssertTrue(evicted.contains("book2"), "Non-active expired job must be evicted")
    }

    func testBudgetOverrunEvictsMultiple() throws {
        let now = Date()
        // 5 books × 300 KB = 1.5 MB; budget = 600 KB → must drop 3 oldest.
        let books = ["b1", "b2", "b3", "b4", "b5"]
        for (i, id) in books.enumerated() {
            let offset = TimeInterval(-(books.count - i) * 3600)
            try plantAudiobook(
                jobId: id,
                totalBytes: 300_000,
                downloadedAt: now.addingTimeInterval(offset),
                lastAccessedAt: now.addingTimeInterval(offset)
            )
        }

        let evicted = runTestEviction(budgetBytes: 600_000, ttlSeconds: 48 * 3600)

        // Oldest 3 (b1, b2, b3) should be evicted; b4, b5 kept.
        XCTAssertEqual(evicted.count, 3)
        XCTAssertTrue(evicted.contains("b1"))
        XCTAssertTrue(evicted.contains("b2"))
        XCTAssertTrue(evicted.contains("b3"))
        XCTAssertFalse(evicted.contains("b4"))
        XCTAssertFalse(evicted.contains("b5"))
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

    func testDeleteAudiobookRemovesFolder() throws {
        let jobId = "deltest-\(UUID().uuidString.prefix(6))"
        let folder = AudiobookDownloadStorage.audiobooksRoot()
            .appendingPathComponent(jobId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let removed = AudiobookCacheEviction.deleteAudiobook(jobId: jobId)

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDeleteNonexistentJobReturnsFalse() {
        let removed = AudiobookCacheEviction.deleteAudiobook(jobId: "nonexistent-\(UUID())")
        XCTAssertFalse(removed)
    }

    func testDefaultConstantsAreReasonable() {
        // 2 GB budget
        XCTAssertEqual(defaultOfflineCacheBudgetBytes, 2 * 1_024 * 1_024 * 1_024)
        // 24 h TTL
        XCTAssertEqual(defaultOfflineCacheTTLSeconds, 24 * 60 * 60)
    }
}
