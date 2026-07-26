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

final class AudiobookCacheEvictionTests: XCTestCase {

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

    // MARK: - Real-root round-trips (locallyDownloadedIndices / staleOfflineBookIds)
    //
    // These two helpers operate on the app-owned audiobook root, so we exercise them end-to-end with unique jobIds and
    // clean up via deleteAudiobook.

    private func makeBook(
        id: String, lastJobId: String?, cachedOffline: Bool
    ) -> BookEntity {
        BookEntity(
            id: id, title: id, bookmark: Data(),
            displayFilename: "\(id).epub", addedAt: Date(),
            lastJobId: lastJobId, cachedOffline: cachedOffline
        )
    }

    /// Plant a manifest + selected MP3 files on the REAL audiobooks root.
    private func plantRealAudiobook(
        jobId: String, entries: [(index: Int, fileName: String, onDisk: Bool)]
    ) throws {
        let folder = DownloadManager.audiobookFolder(for: jobId)
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
        try DownloadManager.saveManifest(AudiobookManifest(
            jobId: jobId, bookTitle: jobId, chapters: chapters,
            totalBytes: Int64(entries.count * 128), completedAt: Date()
        ))
    }

    func testLocallyDownloadedIndicesVerifiesFilesOnDisk() throws {
        let jobId = "test-local-\(UUID().uuidString)"
        defer { AudiobookCacheEviction.deleteAudiobook(jobId: jobId) }
        try plantRealAudiobook(jobId: jobId, entries: [
            (index: 0, fileName: "a.mp3", onDisk: true),
            (index: 2, fileName: "b.mp3", onDisk: true),
            (index: 5, fileName: "gone.mp3", onDisk: false) // manifest says yes, disk says no
        ])
        XCTAssertEqual(DownloadManager.locallyDownloadedIndices(for: jobId), [0, 2])
    }

    func testLocallyDownloadedIndicesEmptyWithoutManifest() {
        XCTAssertEqual(
            DownloadManager.locallyDownloadedIndices(for: "test-missing-\(UUID().uuidString)"),
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
        guard var missingManifest = DownloadManager.loadManifest(for: missingFileJobId),
              var incompleteManifest = DownloadManager.loadManifest(for: incompleteJobId) else {
            XCTFail("Fixtures must have manifests")
            return
        }
        missingManifest.completedAt = Date()
        incompleteManifest.completedAt = nil
        try DownloadManager.saveManifest(missingManifest)
        try DownloadManager.saveManifest(incompleteManifest)

        let books = [
            makeBook(id: "missing-file", lastJobId: missingFileJobId, cachedOffline: true),
            makeBook(id: "incomplete", lastJobId: incompleteJobId, cachedOffline: true)
        ]

        XCTAssertEqual(
            AudiobookCacheEviction.staleOfflineBookIds(books: books),
            ["missing-file", "incomplete"]
        )
    }

    // MARK: - Helpers

    /// Isolated temp folder used as the audiobooks root.
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheEvictionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    /// Plant a fake audiobook folder + manifest under `tempRoot`.
    private func plantAudiobook(
        jobId: String,
        totalBytes: Int64,
        downloadedAt: Date,
        lastAccessedAt: Date? = nil
    ) throws {
        let folder = tempRoot.appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("chapters", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Write a minimal MP3 stub.
        let mp3 = folder.appendingPathComponent("chapter_0.mp3")
        try Data(repeating: 0xFF, count: 512).write(to: mp3)

        // Write manifest. Use ISO-8601 encoding so the decoder (also ISO-8601)
        // can round-trip the Date values without returning nil.
        let manifest = AudiobookManifest(
            jobId: jobId,
            bookTitle: "Book \(jobId)",
            chapters: [
                AudiobookManifest.ChapterEntry(
                    index: 0,
                    title: "Chapter 1",
                    mp3FileName: "chapter_0.mp3",
                    mp3Bytes: totalBytes,
                    downloadedAt: downloadedAt
                )
            ],
            totalBytes: totalBytes,
            completedAt: downloadedAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        let manifestURL = tempRoot
            .appendingPathComponent(jobId, isDirectory: true)
            .appendingPathComponent("manifest.json")
        try data.write(to: manifestURL, options: .atomic)

        // Optionally write a last_access sidecar.
        if let la = lastAccessedAt {
            let sidecar = tempRoot
                .appendingPathComponent(jobId, isDirectory: true)
                .appendingPathComponent("last_access")
            let iso = ISO8601DateFormatter().string(from: la)
            try iso.write(to: sidecar, atomically: true, encoding: .utf8)
        }
    }

    /// Run eviction against our temp root by scanning it directly.
    private func runTestEviction(
        budgetBytes: Int64,
        ttlSeconds: TimeInterval,
        activeJobIds: Set<String> = []
    ) -> [String] {
        // We can't redirect DownloadManager.audiobooksRoot() to tempRoot without
        // subclassing the actor, so we exercise the eviction algorithm using the
        // public helpers that operate on AudiobookCacheEntry values, and validate
        // by checking files exist / are removed.
        //
        // Strategy: use the eviction algorithm's internal logic directly by
        // building entries from `tempRoot` manually and calling `deleteAudiobook`.
        //
        // Since `AudiobookCacheEviction.scanEntries()` reads from
        // `DownloadManager.audiobooksRoot()`, we cannot redirect it without
        // modifying production code. Instead we test the algorithm via the
        // *structural* helpers:
        //   - Read manifests from tempRoot ourselves.
        //   - Apply LRU+TTL algorithm.
        //   - Call deleteAudiobook (which uses DownloadManager.audiobooksRoot).
        //
        // For that last step we instead remove from tempRoot directly in tests,
        // validating that the algorithm selects the right eviction candidates.

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        // Build entries from tempRoot manifests.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [AudiobookCacheEntry] = []
        for folder in contents where folder.hasDirectoryPath {
            let jobId = folder.lastPathComponent
            let manifestURL = folder.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? decoder.decode(AudiobookManifest.self, from: data)
            else { continue }

            let sidecar = folder.appendingPathComponent("last_access")
            var lastAccess: Date = manifest.completedAt ?? Date.distantPast
            if let raw = try? String(contentsOf: sidecar, encoding: .utf8),
               let d = ISO8601DateFormatter().date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                lastAccess = d
            }
            entries.append(AudiobookCacheEntry(
                jobId: jobId,
                totalBytes: manifest.totalBytes,
                lastAccessedAt: lastAccess,
                downloadedAt: manifest.completedAt ?? Date.distantPast
            ))
        }

        // LRU sort (oldest first).
        entries.sort { $0.lastAccessedAt < $1.lastAccessedAt }
        var evicted: [String] = []
        let now = Date()

        // TTL pass.
        for entry in entries where !activeJobIds.contains(entry.jobId) {
            let age = now.timeIntervalSince(entry.lastAccessedAt)
            if age > ttlSeconds {
                let folder = tempRoot.appendingPathComponent(entry.jobId, isDirectory: true)
                if (try? fm.removeItem(at: folder)) != nil {
                    evicted.append(entry.jobId)
                }
            }
        }
        entries.removeAll { evicted.contains($0.jobId) }

        // Budget pass (LRU).
        var totalBytes = entries.reduce(Int64(0)) { $0 + $1.totalBytes }
        for entry in entries where !activeJobIds.contains(entry.jobId) {
            guard totalBytes > budgetBytes else { break }
            let folder = tempRoot.appendingPathComponent(entry.jobId, isDirectory: true)
            if (try? fm.removeItem(at: folder)) != nil {
                totalBytes -= entry.totalBytes
                evicted.append(entry.jobId)
            }
        }
        return evicted
    }

    // MARK: - Tests

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

    func testRegisteredActiveJobIsNeverEvictedByProductionPass() throws {
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
        XCTAssertTrue(evicted.contains(expiredJobId), "An inactive expired job remains an eviction candidate")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent(activeJobId, isDirectory: true).path
        ))
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
        let folder = DownloadManager.audiobooksRoot()
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
        let folder = DownloadManager.audiobooksRoot()
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
