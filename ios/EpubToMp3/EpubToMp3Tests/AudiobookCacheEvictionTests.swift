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


    // MARK: - Real-root round-trips (locallyDownloadedIndices / staleOfflineBookIds)
    //
    // These two helpers operate on the app-owned audiobook root, so we exercise them end-to-end with unique jobIds and
    // clean up via deleteAudiobook.

    func makeBook(
        id: String, lastJobId: String?, cachedOffline: Bool
    ) -> BookEntity {
        BookEntity(
            id: id, title: id, bookmark: Data(),
            displayFilename: "\(id).epub", addedAt: Date(),
            lastJobId: lastJobId, cachedOffline: cachedOffline
        )
    }

    /// Plant a manifest + selected MP3 files on the REAL audiobooks root.
    func plantRealAudiobook(
        jobId: String, entries: [(index: Int, fileName: String, onDisk: Bool)]
    ) throws {
        let folder = AudiobookDownloadStorage.audiobookFolder(for: jobId)
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





    // MARK: - Helpers

    /// Isolated temp folder used as the audiobooks root.
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

    /// Plant a fake audiobook folder + manifest under `tempRoot`.
    func plantAudiobook(
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
    func runTestEviction(
        budgetBytes: Int64,
        ttlSeconds: TimeInterval,
        activeJobIds: Set<String> = []
    ) -> [String] {
        // We can't redirect AudiobookDownloadStorage.audiobooksRoot() to tempRoot without
        // subclassing the actor, so we exercise the eviction algorithm using the
        // public helpers that operate on AudiobookCacheEntry values, and validate
        // by checking files exist / are removed.
        //
        // Strategy: use the eviction algorithm's internal logic directly by
        // building entries from `tempRoot` manually and calling `deleteAudiobook`.
        //
        // Since `AudiobookCacheEviction.scanEntries()` reads from
        // `AudiobookDownloadStorage.audiobooksRoot()`, we cannot redirect it without
        // modifying production code. Instead we test the algorithm via the
        // *structural* helpers:
        //   - Read manifests from tempRoot ourselves.
        //   - Apply LRU+TTL algorithm.
        //   - Call deleteAudiobook (which uses AudiobookDownloadStorage.audiobooksRoot).
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










}
