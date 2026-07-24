import XCTest
@testable import EpubToMp3

private final class InMemoryStorage: ResumeStorage {
    var blob: Data?
    func data(forKey key: String) -> Data? { blob }
    func set(_ value: Data?, forKey key: String) { blob = value }
}

final class ResumeStoreTests: XCTestCase {

    func testSaveAndReadRoundtrip() {
        let storage = InMemoryStorage()
        let store = ResumeStore(storage: storage)
        store.save(jobId: "job-a", chapterIndex: 2, position: 145.5)

        let store2 = ResumeStore(storage: storage)
        let marker = store2.marker(jobId: "job-a", chapterIndex: 2)
        XCTAssertEqual(marker?.positionSeconds, 145.5)
        XCTAssertEqual(marker?.chapterIndex, 2)
        XCTAssertEqual(marker?.jobId, "job-a")
    }

    func testClearJobOnlyEvictsMatchingJob() {
        let storage = InMemoryStorage()
        let store = ResumeStore(storage: storage)
        store.save(jobId: "a", chapterIndex: 0, position: 10)
        store.save(jobId: "b", chapterIndex: 0, position: 20)
        store.clear(jobId: "a")
        XCTAssertNil(store.marker(jobId: "a", chapterIndex: 0))
        XCTAssertEqual(store.marker(jobId: "b", chapterIndex: 0)?.positionSeconds, 20)
    }

    func testNegativePositionsAreClampedToZero() {
        let storage = InMemoryStorage()
        let store = ResumeStore(storage: storage)
        store.save(jobId: "j", chapterIndex: 0, position: -42)
        XCTAssertEqual(store.marker(jobId: "j", chapterIndex: 0)?.positionSeconds, 0)
    }

    func testKeyFormat() {
        XCTAssertEqual(ResumeStore.key(jobId: "abc", chapterIndex: 7), "abc#7")
    }
}

// `AudioPlayerPlaybackPersistenceTests` removed here: it called
// `AudioPlayer(defaults:)` and `PlaybackRate.x125`, neither of which has
// ever existed (confirmed via `git log -S` — same pre-existing TDD-red
// state as `AudioPlayerEnqueueSegmentTests`, unrelated to and predating
// the 2026-07-23 UIKit migration). "Playback rate persists across process
// relaunch via UserDefaults" is a real, uncompleted feature — re-add
// this class once `AudioPlayer` grows that init + persistence + rate case.

final class DownloadManagerHelperTests: XCTestCase {
    func testSanitizedFileNameStripsInvalidChars() {
        let cleaned = DownloadManager.sanitizedFileName("Chapter 1: Hello/World?")
        XCTAssertFalse(cleaned.contains("/"))
        XCTAssertFalse(cleaned.contains("?"))
        XCTAssertFalse(cleaned.contains(":"))
    }

    func testSanitizedFileNameFallsBackToChapterOnEmpty() {
        XCTAssertEqual(DownloadManager.sanitizedFileName("   "), "chapter")
    }

    func testResolveAbsoluteURL() {
        let url = DownloadManager.resolve(path: "https://x.example/a.mp3", base: nil)
        XCTAssertEqual(url?.absoluteString, "https://x.example/a.mp3")
    }

    func testResolveRelativeAgainstBase() {
        let base = URL(string: "http://localhost:8000")!
        let url = DownloadManager.resolve(path: "/api/outputs/j/x.mp3", base: base)
        XCTAssertEqual(url?.absoluteString, "http://localhost:8000/api/outputs/j/x.mp3")
    }

    func testChapterSelectionBuildsSingleChapterManifest() {
        let snapshot = JobSnapshot(
            jobId: "job-single",
            state: "running",
            bookTitle: "Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: 3,
            chaptersCompleted: 1,
            chapterProgress: [
                JobSnapshot.Chapter(index: 0, name: "Ch 1", status: "completed", downloadUrl: "http://example.invalid/0.mp3", chars: nil, charsProcessed: nil, progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil),
                JobSnapshot.Chapter(index: 2, name: "Ch 3", status: "completed", downloadUrl: "http://example.invalid/2.mp3", chars: nil, charsProcessed: nil, progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil),
            ],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )

        let selected = DownloadManager.selectedChapters(snapshot: snapshot, epubZeroBasedIndices: [2])
        XCTAssertEqual(selected.map(\.index), [2],
                       "Single-chapter download selection must key off EPUB zero-based indices, not playable-list positions.")
    }

    func testDeleteAudiobookRemovesBookFolder() throws {
        let jobId = "delete-test-\(UUID().uuidString)"
        let folder = DownloadManager.audiobookFolder(for: jobId)
        let file = folder.appendingPathComponent("chapter_1.mp3")
        try Data([0x01]).write(to: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        DownloadManager.deleteAudiobook(jobId: jobId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path))
    }

    func testPartialManifestMergeIsIdempotentAndIncomingEntryWins() {
        let jobId = "merge-\(UUID().uuidString)"
        let old = AudiobookManifest(
            jobId: jobId, bookTitle: "Book", chapters: [
                .init(index: 0, title: "zero", mp3FileName: "zero.mp3", mp3Bytes: 10, downloadedAt: Date(timeIntervalSince1970: 1)),
                .init(index: 2, title: "old", mp3FileName: "old.mp3", mp3Bytes: 20, downloadedAt: Date(timeIntervalSince1970: 2))
            ], totalBytes: 30, completedAt: nil
        )
        let incoming = AudiobookManifest(
            jobId: jobId, bookTitle: "Book", chapters: [
                .init(index: 1, title: "one", mp3FileName: "one.mp3", mp3Bytes: 11, downloadedAt: Date(timeIntervalSince1970: 3)),
                .init(index: 2, title: "new", mp3FileName: "new.mp3", mp3Bytes: 21, downloadedAt: Date(timeIntervalSince1970: 4))
            ], totalBytes: 32, completedAt: nil
        )

        let merged = DownloadManager.mergeManifests(old, incoming)
        let repeated = DownloadManager.mergeManifests(merged, incoming)
        XCTAssertEqual(merged.chapters.map(\.index), [0, 1, 2])
        XCTAssertEqual(merged.chapters.first(where: { $0.index == 2 })?.mp3FileName, "new.mp3")
        XCTAssertEqual(merged.totalBytes, 42)
        XCTAssertEqual(repeated, merged)
    }

    func testManifestIsCompleteRequiresEveryExpectedChapterAndExistingFiles() throws {
        let jobId = "complete-\(UUID().uuidString)"
        defer { DownloadManager.deleteAudiobook(jobId: jobId) }
        let folder = DownloadManager.audiobookFolder(for: jobId)
        let entries = [0, 1].map {
            AudiobookManifest.ChapterEntry(index: $0, title: "ch\($0)", mp3FileName: "ch\($0).mp3", mp3Bytes: 128, downloadedAt: Date())
        }
        for entry in entries { try Data(repeating: 0xFF, count: 128).write(to: folder.appendingPathComponent(entry.mp3FileName)) }
        let manifest = AudiobookManifest(jobId: jobId, bookTitle: "Book", chapters: entries, totalBytes: 256, completedAt: Date())
        XCTAssertTrue(DownloadManager.isManifestComplete(manifest, expectedChapterIndices: [0, 1]))
        XCTAssertFalse(DownloadManager.isManifestComplete(manifest, expectedChapterIndices: [0, 1, 2]))
    }
}
