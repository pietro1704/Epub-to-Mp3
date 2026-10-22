#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerStreamingTests {
    @MainActor
    func testValidatedRustChapterSnapshotsStartOnListenAndAppendInOrder() throws {
        let player = AudioPlayer()
        let jobID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rust-chapter-stream-\(jobID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: root)
        }
        let firstURL = root.appendingPathComponent("0001-first.mp3")
        let secondURL = root.appendingPathComponent("0002-second.mp3")
        try fakeMP3().write(to: firstURL)
        try fakeMP3().write(to: secondURL)

        let pending = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: "Rust stream", bookAuthor: "Author",
            coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil, language: "en",
            progressPercent: 0, chaptersTotal: 2, chaptersCompleted: 0,
            chapterProgress: [], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
        player.isConverting = true
        player.resume()

        let first = JobSnapshot.Chapter(
            index: 0, name: "First", status: "completed", downloadUrl: firstURL.path,
            chars: 3_000, charsProcessed: 3_000, progressRatio: 1,
            durationSeconds: nil, startedAt: nil, completedAt: nil
        )
        let firstUpdate = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: "Rust stream", bookAuthor: "Author",
            coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil, language: "en",
            progressPercent: 50, chaptersTotal: 2, chaptersCompleted: 1,
            chapterProgress: [first], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        player.updateSnapshot(firstUpdate)

        XCTAssertTrue(player.isPlaying, "Listen intent must start as soon as a validated Rust chapter is queued.")
        XCTAssertEqual(player.testHook_playbackChapterCount(), 1)
        XCTAssertEqual((player.testHook_currentPlayerItem()?.asset as? AVURLAsset)?.url, firstURL)

        let second = JobSnapshot.Chapter(
            index: 1, name: "Second", status: "completed", downloadUrl: secondURL.path,
            chars: 3_200, charsProcessed: 3_200, progressRatio: 1,
            durationSeconds: nil, startedAt: nil, completedAt: nil
        )
        let secondUpdate = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: "Rust stream", bookAuthor: "Author",
            coverUrl: nil, coverMimeType: nil, engine: "edge", voice: nil, language: "en",
            progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2,
            chapterProgress: [first, second], outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        player.updateSnapshot(secondUpdate)

        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.testHook_playbackChapterCount(), 2,
                       "Later validated chapters must append without resetting the active chapter.")
        XCTAssertTrue(player.isConverting, "The stream remains live until Rust reports a terminal snapshot.")
    }

    /// Regression: `play(snapshot:startingAt:)` used to call `queue.play()`
    /// unconditionally. Now it only sets up the queue; playback only starts
    /// on explicit user intent.
    @MainActor
    func testPlaySnapshotPreparesWithoutAutoStart() {
        let player = AudioPlayer()
        XCTAssertFalse(player.isPlaying)
        let snap = JobSnapshot.previewSample
        player.play(snapshot: snap, startingAt: 0)
        XCTAssertFalse(player.isPlaying,
            "play(snapshot:startingAt:) must load without auto-starting playback")
    }

    @MainActor
    func testManualRustConversionSnapshotStaysPaused() throws {
        let player = AudioPlayer()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manual-rust-\(UUID().uuidString).mp3")
        try fakeMP3().write(to: fileURL)
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: fileURL)
        }
        let snapshot = JobSnapshot(
            jobId: UUID().uuidString, state: "finished", bookTitle: "Manual Rust",
            bookAuthor: nil, coverUrl: nil, coverMimeType: nil, engine: "edge",
            voice: nil, language: "en", progressPercent: 100, chaptersTotal: 1,
            chaptersCompleted: 1,
            chapterProgress: [.init(
                index: 0, name: "Chapter", status: "completed", downloadUrl: fileURL.path,
                chars: 3_000, charsProcessed: 3_000, progressRatio: 1,
                durationSeconds: nil, startedAt: nil, completedAt: nil
            )],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )

        player.play(snapshot: snapshot, restoreAutoplay: false)

        XCTAssertNotNil(player.testHook_currentPlayerItem())
        XCTAssertFalse(player.isPlaying, "Manual conversion prepares audio without autoplay.")
    }

    @MainActor
    func testUpdateSnapshotBuildsQueueWhenFirstPlayableChapterArrives() {
        let player = AudioPlayer(backendBaseURL: URL(string: "https://example.com")!)
        let pending = snapshot(chapters: [chapter(index: 0, url: nil)], state: "running")
        let playable = snapshot(chapters: [chapter(index: 0, url: "/audio/ch0.mp3")], state: "running")

        player.play(snapshot: pending, startingAt: 0)
        XCTAssertFalse(player.isPlaying)

        player.updateSnapshot(playable)
        player.resume()

        XCTAssertTrue(player.isPlaying,
            "The first playable SSE snapshot must create an AVQueuePlayer so a normal Play tap can start audio without reopening the reader.")
    }

    @MainActor
    func testResumeBeforeFirstPlayableChapterAutoplaysWhenSnapshotArrives() {
        let player = AudioPlayer(backendBaseURL: URL(string: "https://example.com")!)
        let pending = snapshot(chapters: [chapter(index: 2, url: nil)], state: "running")
        let playable = snapshot(chapters: [chapter(index: 2, url: "/audio/ch2.mp3")], state: "running")

        player.play(snapshot: pending, startingAt: 2)
        player.resume()
        XCTAssertFalse(player.isPlaying,
            "No player exists yet, but resume() should remember the user's intent to play.")

        player.updateSnapshot(playable)

        XCTAssertTrue(player.isPlaying,
            "If the user tapped Play while waiting for streaming audio, the first playable chapter should start as soon as the queue is built.")
    }

    @MainActor
    func testChaptersToAppendUsesChapterIdentityForPriorityWraparound() {
        let old = [chapter(index: 10, url: "/audio/ch10.mp3"),
                   chapter(index: 11, url: "/audio/ch11.mp3")]
        let new = [chapter(index: 0, url: "/audio/ch0.mp3"),
                   chapter(index: 10, url: "/audio/ch10.mp3"),
                   chapter(index: 11, url: "/audio/ch11.mp3")]

        let appended = PlaybackChapterQueue.chaptersToAppend(old: old, new: new)

        XCTAssertEqual(appended.map(\.index), [0],
            "Priority streaming can wrap to earlier EPUB indices; append decisions must diff by chapter identity instead of suffix(count).")
    }
}
#endif
