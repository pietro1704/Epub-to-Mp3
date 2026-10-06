import XCTest
import MediaPlayer
@testable import EpubToMp3

final class PlaybackBindingStoreTests: XCTestCase {

    // XCTest invokes lifecycle hooks outside the MainActor but serially for a
    // test case; these fixtures bridge that documented boundary only.
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite = "playback.binding.tests.\(UUID().uuidString)"

    nonisolated override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    nonisolated override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try await super.tearDown()
    }

    @MainActor
    func testSetCurrentlyPlayingPersistsBookAndChapter() {
        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: "book-123",
            chapterIndex: 4,
            defaults: defaults
        )
        XCTAssertEqual(
            defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey),
            "book-123"
        )
        XCTAssertEqual(
            defaults.integer(forKey: AudioPlayer.currentChapterIndexDefaultsKey),
            4
        )
    }

    @MainActor
    func testSetCurrentlyPlayingClearsBookWhenNil() {
        defaults.set("seed", forKey: AudioPlayer.currentBookIDDefaultsKey)
        defaults.set(7, forKey: AudioPlayer.currentChapterIndexDefaultsKey)

        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: nil,
            chapterIndex: 99,
            defaults: defaults
        )
        XCTAssertNil(defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey))
        XCTAssertNil(defaults.object(forKey: AudioPlayer.currentChapterIndexDefaultsKey))
    }

    @MainActor
    func testSetCurrentlyPlayingClampsNegativeChapterIndexToZero() {
        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: "book-x",
            chapterIndex: -3,
            defaults: defaults
        )
        XCTAssertEqual(
            defaults.integer(forKey: AudioPlayer.currentChapterIndexDefaultsKey),
            0
        )
    }

    @MainActor
    func testSetCurrentlyPlayingTreatsEmptyStringAsNil() {
        defaults.set("seed", forKey: AudioPlayer.currentBookIDDefaultsKey)

        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: "",
            chapterIndex: 0,
            defaults: defaults
        )
        XCTAssertNil(defaults.string(forKey: AudioPlayer.currentBookIDDefaultsKey))
    }

    @MainActor
    func testSetCurrentlyPlayingNeverClaimsWidgetIsPlaying() {
        let appGroupID = WidgetDataSync.appGroupID
        guard let groupDefaults = UserDefaults(suiteName: appGroupID) else {
            XCTFail("App Group suite must be constructible in tests")
            return
        }
        let previousBookID = groupDefaults.object(forKey: "currentlyPlayingBookId")
        let previousIsPlaying = groupDefaults.object(forKey: "widget.nowPlayingIsPlaying")
        defer {
            if let previousBookID {
                groupDefaults.set(previousBookID, forKey: "currentlyPlayingBookId")
            } else {
                groupDefaults.removeObject(forKey: "currentlyPlayingBookId")
            }
            if let previousIsPlaying {
                groupDefaults.set(previousIsPlaying, forKey: "widget.nowPlayingIsPlaying")
            } else {
                groupDefaults.removeObject(forKey: "widget.nowPlayingIsPlaying")
            }
        }

        PlaybackBindingStore.setCurrentlyPlaying(
            bookID: "book-123",
            chapterIndex: 2,
            chapterName: "Chapter 3"
        )

        XCTAssertEqual(groupDefaults.string(forKey: "currentlyPlayingBookId"), "book-123")
        XCTAssertEqual(groupDefaults.bool(forKey: "widget.nowPlayingIsPlaying"), false)
    }

    @MainActor
    func testNowPlayingChapterTitleStripsGenericChapterPrefix() {
        XCTAssertEqual(
            AudioPlayer.preferredChapterTitle(
                primary: "Chapter 2: The Shadow of the Past",
                secondary: "Chapter 2",
                fallback: "Chapter"
            ),
            "The Shadow of the Past"
        )
    }

    @MainActor
    func testNowPlayingMetadataUsesChapterAsTitleAndBookAsAlbum() {
        let chapter = JobSnapshot.Chapter(
            index: 11,
            name: "Chapter 2: The Shadow of the Past",
            status: "completed",
            downloadUrl: "chapter-2.mp3",
            chars: nil,
            charsProcessed: nil,
            progressRatio: 1,
            durationSeconds: 120,
            startedAt: nil,
            completedAt: nil
        )
        let snapshot = JobSnapshot(
            jobId: "job",
            state: "finished",
            bookTitle: "The Lord of the Rings",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: "en",
            progressPercent: 100,
            chaptersTotal: 12,
            chaptersCompleted: 12,
            chapterProgress: [chapter],
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
        let player = AudioPlayer()
        player.setSnapshot(snapshot)
        let info = player.makeNowPlayingInfo()

        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "The Shadow of the Past")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "The Lord of the Rings")
    }

    @MainActor
    func testPlaybackBindingStoreReplacesLegacyNowPlayingViewHelper() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try readSourceFileIfAvailable(
            at: projectRoot.appendingPathComponent("EpubToMp3/App/EpubToMp3App.swift")
        )
        let bookOpenSource = try readSourceFileIfAvailable(
            at: projectRoot.appendingPathComponent("EpubToMp3/Features/Reader/Views/BookOpenScreenController.swift")
        )

        XCTAssertTrue(appSource.contains("PlaybackBindingStore.setCurrentlyPlaying"))
        XCTAssertTrue(bookOpenSource.contains("ReaderSessionState.setCurrentlyReading"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: projectRoot.appendingPathComponent("EpubToMp3/Features/Playback/Views/NowPlayingView.swift").path
        ))
    }

}
