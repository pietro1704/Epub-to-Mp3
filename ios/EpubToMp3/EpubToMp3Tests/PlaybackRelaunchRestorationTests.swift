#if os(macOS)
import XCTest
@testable import EpubToMp3

@MainActor
final class PlaybackRelaunchRestorationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "PlaybackRelaunchRestoration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testRestoresPausedAtPersistedChapterWithoutAutoplay() async throws {
        defaults.set("book", forKey: AudioPlayer.currentBookIDDefaultsKey)
        defaults.set(4, forKey: AudioPlayer.currentChapterIndexDefaultsKey)
        defaults.set("another-reader", forKey: ReaderSessionState.currentlyReadingBookIDKey)
        defaults.set(0, forKey: AudioPlayer.readerCurrentChapterIndexDefaultsKey)
        let player = makePlayer()
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp3")
        defer {
            player.stop()
            try? FileManager.default.removeItem(at: audio)
        }
        try LegacyAudioImportFixture.audio.write(to: audio)
        let restored = expectation(description: "restored")
        PlaybackRelaunchRestoration.restore(
            bookID: "book", player: player, owner: self,
            isListeningActive: { false },
            loadSnapshot: { Self.snapshot(book: "book", audio: audio) }, onRestored: { restored.fulfill() })
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(player.snapshot?.jobId, "embedded-book")
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(player.hasLoadedAudioQueue)
        XCTAssertEqual(player.currentChapterIndex, 1, "Restore the playing book’s persisted source index.")
    }

    func testListeningStartedDuringTheAwaitWins() async throws {
        defaults.set("book", forKey: AudioPlayer.currentBookIDDefaultsKey)
        let player = makePlayer()
        var listening = false
        let loaded = expectation(description: "loaded")
        PlaybackRelaunchRestoration.restore(
            bookID: "book", player: player, owner: self,
            isListeningActive: { listening },
            loadSnapshot: { listening = true; loaded.fulfill(); return Self.snapshot(book: "book") },
            onRestored: { XCTFail("restore must not overwrite a listening start") })
        await fulfillment(of: [loaded], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(player.snapshot)
    }

    func testBookSwitchDuringTheAwaitRestoresNothing() async throws {
        defaults.set("book", forKey: AudioPlayer.currentBookIDDefaultsKey)
        defaults.set("book", forKey: ReaderSessionState.currentlyReadingBookIDKey)
        let player = makePlayer()
        let loaded = expectation(description: "loaded")
        PlaybackRelaunchRestoration.restore(
            bookID: "book", player: player, owner: self,
            isListeningActive: { false },
            loadSnapshot: { [defaults] in
                defaults!.set("other", forKey: AudioPlayer.currentBookIDDefaultsKey)
                loaded.fulfill()
                return Self.snapshot(book: "book")
            },
            onRestored: { XCTFail("restore must not play a book that is no longer current") })
        await fulfillment(of: [loaded], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(player.snapshot)
    }

    func testReleasedOwnerRestoresNothing() async throws {
        defaults.set("book", forKey: AudioPlayer.currentBookIDDefaultsKey)
        let player = makePlayer()
        var owner: NSObject? = NSObject()
        PlaybackRelaunchRestoration.restore(
            bookID: "book", player: player, owner: owner!,
            isListeningActive: { false },
            loadSnapshot: { Self.snapshot(book: "book") },
            onRestored: { XCTFail("a released owner has nothing to restore into") })
        owner = nil
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(player.snapshot)
    }

    private func makePlayer() -> AudioPlayer {
        AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
    }

    private static func snapshot(book: String, audio: URL? = nil) -> JobSnapshot {
        let chapters = [0, 4].map { index in
            JobSnapshot.Chapter(
                index: index, name: "Chapter \(index)", status: "completed",
                downloadUrl: audio?.absoluteString ?? "file:///restore/chapter-\(index).mp3", chars: 100, charsProcessed: 100,
                progressRatio: 1, durationSeconds: 10, startedAt: 1, completedAt: 2, textOffset: 0)
        }
        return JobSnapshot(
            jobId: "embedded-\(book)", state: "finished", bookTitle: "Title", bookAuthor: "Author",
            coverUrl: nil, coverMimeType: nil, engine: "piper", voice: "faber", language: "pt-BR",
            progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2, chapterProgress: chapters,
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: 2,
            chapterIndexBase: 0, sourceChaptersTotal: 5)
    }
}
#endif
