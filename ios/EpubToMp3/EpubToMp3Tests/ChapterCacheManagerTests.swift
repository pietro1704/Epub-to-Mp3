// ChapterCacheManagerTests.swift
//
// Tests for `ChapterCacheManager`. All tests run on the @MainActor
// because `ChapterCacheManager` is a `@MainActor` class.
//
// Network / Edge-TTS synthesis is never invoked — tests only exercise:
//   - `status(for:)` initial state (`.notStarted` for all chapters).
//   - `refreshCachedIndices()` after writing a fake MP3 to the cache dir.
//   - `prefetchNext` does not enqueue chapters that are already cached.
//   - `downloadAll` enqueues only uncached chapters.
//   - `cancelAll` clears `generatingIndices` and `activeTasks`.
//   - `status(for:)` returns `.cached` after a file is seeded on disk.
//
// Each test uses a unique `bookId` so cache directories are isolated.
// `tmp_path`-equivalent is achieved via `FileManager.temporaryDirectory`
// with a UUID sub-folder; cleaned up in `tearDown`.

import XCTest
@testable import EpubToMp3

@MainActor
final class ChapterCacheManagerTests: XCTestCase {

    // MARK: - Helpers

    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try await super.tearDown()
    }

    /// Create an isolated cache root and a matching `ChapterCacheManager`.
    /// The manager uses the Caches directory with `epub2mp3-tts/<bookId>`.
    private func makeManager(
        chapters: [EbookFulltext.Chapter],
        bookId: String? = nil
    ) -> (ChapterCacheManager, String, URL) {
        let id = bookId ?? "cm-\(UUID().uuidString.prefix(8))"
        let cacheRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("epub2mp3-tts/\(id)", isDirectory: true)
        tempDirs.append(cacheRoot)
        let mgr = ChapterCacheManager(bookId: id, chapters: chapters, voice: "en-US-AriaNeural")
        return (mgr, id, cacheRoot)
    }

    private func makeChapter(index: Int, text: String = "Hello world paragraph.") -> EbookFulltext.Chapter {
        EbookFulltext.Chapter(
            index: index,
            name: "Chapter \(index)",
            text: text,
            html: nil,
            css: nil,
            charCount: text.count,
            segments: nil
        )
    }

    // MARK: - Initial state

    func testInitialStatusIsNotStartedForAllChapters() {
        let chapters = (1...3).map { makeChapter(index: $0) }
        let (mgr, _, _) = makeManager(chapters: chapters)

        for ch in chapters {
            XCTAssertEqual(mgr.status(for: ch.index - 1), .notStarted,
                "All chapters should start as .notStarted; got \(mgr.status(for: ch.index - 1)) for index \(ch.index)")
        }
    }

    func testGeneratingIndicesIsEmptyOnInit() {
        let (mgr, _, _) = makeManager(chapters: [makeChapter(index: 1)])

        XCTAssertTrue(mgr.generatingIndices.isEmpty)
    }

    // MARK: - refreshCachedIndices

    func testRefreshDetectsFakeMP3OnDisk() throws {
        let chapters = [makeChapter(index: 1)]
        let (mgr, _, cacheRoot) = makeManager(chapters: chapters)

        // Write a fake MP3 (> 100 bytes) to simulate a cached chapter.
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let fakeAudio = Data(repeating: 0xFF, count: 200)
        let chapterFile = cacheRoot.appendingPathComponent("chapter_0.mp3")
        try fakeAudio.write(to: chapterFile)

        mgr.refreshCachedIndices()

        XCTAssertTrue(mgr.cachedIndices.contains(0),
            "refreshCachedIndices must pick up the seeded MP3 at index 0")
        XCTAssertEqual(mgr.status(for: 0), .cached)
    }

    func testRefreshDetectsSparseBackendIndexUsingZeroBasedCacheIndex() throws {
        let chapters = [makeChapter(index: 1), makeChapter(index: 3), makeChapter(index: 5)]
        let (mgr, _, cacheRoot) = makeManager(chapters: chapters)

        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 200)
            .write(to: cacheRoot.appendingPathComponent("chapter_2.mp3"))

        mgr.refreshCachedIndices()

        XCTAssertEqual(mgr.cachedIndices, [2],
                       "backend index 3 must use EPUB zero-based cache index 2")
    }

    func testRefreshIgnoresTinyFiles() throws {
        let chapters = [makeChapter(index: 1)]
        let (mgr, _, cacheRoot) = makeManager(chapters: chapters)

        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        // Write a file smaller than 100 bytes — should be ignored.
        let tinyFile = cacheRoot.appendingPathComponent("chapter_0.mp3")
        try Data(repeating: 0x00, count: 50).write(to: tinyFile)

        mgr.refreshCachedIndices()

        XCTAssertFalse(mgr.cachedIndices.contains(0),
            "Files < 100 bytes must not be counted as cached")
        XCTAssertEqual(mgr.status(for: 0), .notStarted)
    }

    func testRefreshDoesNotMarkAbsentChaptersAsCached() {
        let chapters = (1...5).map { makeChapter(index: $0) }
        let (mgr, _, _) = makeManager(chapters: chapters)

        // No files written — all should be .notStarted after refresh.
        mgr.refreshCachedIndices()

        XCTAssertTrue(mgr.cachedIndices.isEmpty,
            "No files on disk must yield an empty cachedIndices set")
    }

    // MARK: - Status transitions

    func testStatusReturnsCachedAfterRefreshFindsFile() throws {
        let chapters = [makeChapter(index: 2)]
        let (mgr, _, cacheRoot) = makeManager(chapters: chapters)

        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 300)
            .write(to: cacheRoot.appendingPathComponent("chapter_1.mp3"))

        mgr.refreshCachedIndices()

        XCTAssertEqual(mgr.status(for: 1), .cached)
    }

    func testStatusNotStartedForChapterWithNoFile() {
        let (mgr, _, _) = makeManager(chapters: [makeChapter(index: 3)])
        XCTAssertEqual(mgr.status(for: 2), .notStarted)
    }

    // MARK: - cancelAll

    func testCancelAllClearsGeneratingIndices() {
        let (mgr, _, _) = makeManager(chapters: [makeChapter(index: 1)])

        // Manually poke `generatingIndices` is not possible (it is
        // `private(set)`). We call `downloadAll` to kick off a task
        // then cancel immediately — the indices should be clear.
        // Note: synthesis won't actually run (no network), but the
        // generatingIndices set is populated synchronously before the
        // Task body runs; cancelAll then removes them.
        mgr.downloadAll()
        mgr.cancelAll()

        XCTAssertTrue(mgr.generatingIndices.isEmpty,
            "cancelAll must clear generatingIndices immediately")
    }

    func testCancelAllIsIdempotent() {
        let (mgr, _, _) = makeManager(chapters: [makeChapter(index: 1)])
        mgr.cancelAll()
        mgr.cancelAll()

        XCTAssertTrue(mgr.generatingIndices.isEmpty)
    }

    func testClearNotificationHopsToMainActor() async throws {
        let chapters = [makeChapter(index: 1)]
        let (mgr, _, cacheRoot) = makeManager(chapters: chapters)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 300)
            .write(to: cacheRoot.appendingPathComponent("chapter_0.mp3"))
        mgr.refreshCachedIndices()
        XCTAssertEqual(mgr.status(for: 0), .cached)

        NotificationCenter.default.post(name: ChapterCacheManager.clearAllNotification, object: nil)
        await Task.yield()

        XCTAssertEqual(mgr.status(for: 0), .notStarted)
    }

    func testClearNotificationObserverSchedulesMainActorCleanup() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Features/Offline/Services/ChapterCacheManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("guard let manager = self else { return }"))
        XCTAssertTrue(source.contains("Task { @MainActor in"))
        XCTAssertTrue(source.contains("manager.clearAll()"))
    }

    func testClearAllCancelsAndRemovesCachedIndices() {
        let (mgr, _, _) = makeManager(chapters: [makeChapter(index: 1)])
        mgr.downloadAll()
        mgr.clearAll()
        XCTAssertTrue(mgr.generatingIndices.isEmpty)
        XCTAssertTrue(mgr.cachedIndices.isEmpty)
    }

    // MARK: - prefetchNext / downloadAll guard against empty text

    func testPrefetchNextSkipsChaptersWithTooShortText() {
        // Chapters with < 10 chars are skipped by the guard in synthesizeChapter.
        let chapters = [
            EbookFulltext.Chapter(
                index: 1, name: "Tiny", text: "Hi",
                html: nil, css: nil, charCount: 2, segments: nil
            )
        ]
        let (mgr, _, _) = makeManager(chapters: chapters)

        mgr.prefetchNext(1, from: -1)

        // No task should be created for such short text.
        XCTAssertTrue(mgr.generatingIndices.isEmpty,
            "Chapters < 10 chars must not enter generatingIndices")
    }

    func testDownloadAllSkipsCachedChapters() throws {
        let chapters = (1...3).map { makeChapter(index: $0, text: "Long enough text here.") }
        let (mgr, _, cacheRoot) = makeManager(chapters: chapters)

        // Seed chapter 0 as already cached.
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try Data(repeating: 0xFF, count: 200)
            .write(to: cacheRoot.appendingPathComponent("chapter_0.mp3"))
        mgr.refreshCachedIndices()

        mgr.downloadAll()
        defer { mgr.cancelAll() }

        // Only chapters 1 and 2 (arrayIndex) should be generating.
        XCTAssertFalse(mgr.generatingIndices.contains(0),
            "Chapter 0 is already cached — must not be re-enqueued")
    }

    func testDownloadChapterEnqueuesOnlyRequestedUncachedChapter() {
        let chapters = (1...3).map { makeChapter(index: $0, text: "Long enough text here.") }
        let (mgr, _, _) = makeManager(chapters: chapters)

        mgr.downloadChapter(1)
        defer { mgr.cancelAll() }

        XCTAssertEqual(mgr.generatingIndices, [1],
                       "downloadChapter must enqueue only the requested zero-based chapter index.")
    }

    // MARK: - Multiple chapters refreshed correctly

    func testRefreshHandlesMultipleCachedChapters() throws {
        let chapters = (1...5).map { makeChapter(index: $0) }
        let (mgr, _, cacheRoot) = makeManager(chapters: chapters)

        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        for idx in [0, 2, 4] {
            try Data(repeating: 0xBB, count: 200)
                .write(to: cacheRoot.appendingPathComponent("chapter_\(idx).mp3"))
        }

        mgr.refreshCachedIndices()

        XCTAssertEqual(mgr.cachedIndices, [0, 2, 4],
            "Only seeded indices must appear in cachedIndices")
        XCTAssertEqual(mgr.status(for: 0), .cached)
        XCTAssertEqual(mgr.status(for: 1), .notStarted)
        XCTAssertEqual(mgr.status(for: 2), .cached)
        XCTAssertEqual(mgr.status(for: 3), .notStarted)
        XCTAssertEqual(mgr.status(for: 4), .cached)
    }
}
