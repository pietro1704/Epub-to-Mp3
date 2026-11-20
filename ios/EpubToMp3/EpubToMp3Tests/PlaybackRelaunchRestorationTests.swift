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
        let player = makePlayer()
        let restored = expectation(description: "restored")
        PlaybackRelaunchRestoration.restore(
            bookID: "book", chapterIndex: 0, player: player, owner: self,
            defaults: defaults, isListeningActive: { false },
            loadSnapshot: { Self.snapshot(book: "book") }, onRestored: { restored.fulfill() })
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(player.snapshot?.jobId, "embedded-book")
        XCTAssertFalse(player.isPlaying)
    }

    func testListeningStartedDuringTheAwaitWins() async throws {
        defaults.set("book", forKey: AudioPlayer.currentBookIDDefaultsKey)
        let player = makePlayer()
        var listening = false
        let loaded = expectation(description: "loaded")
        PlaybackRelaunchRestoration.restore(
            bookID: "book", chapterIndex: 0, player: player, owner: self,
            defaults: defaults, isListeningActive: { listening },
            loadSnapshot: { listening = true; loaded.fulfill(); return Self.snapshot(book: "book") },
            onRestored: { XCTFail("restore must not overwrite a listening start") })
        await fulfillment(of: [loaded], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(player.snapshot)
    }

    func testBookSwitchDuringTheAwaitRestoresNothing() async throws {
        defaults.set("book", forKey: AudioPlayer.currentBookIDDefaultsKey)
        let player = makePlayer()
        let loaded = expectation(description: "loaded")
        PlaybackRelaunchRestoration.restore(
            bookID: "book", chapterIndex: 0, player: player, owner: self,
            defaults: defaults, isListeningActive: { false },
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
            bookID: "book", chapterIndex: 0, player: player, owner: owner!,
            defaults: defaults, isListeningActive: { false },
            loadSnapshot: { Self.snapshot(book: "book") },
            onRestored: { XCTFail("a released owner has nothing to restore into") })
        owner = nil
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(player.snapshot)
    }

    private func makePlayer() -> AudioPlayer {
        AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
    }

    private static func snapshot(book: String) -> JobSnapshot {
        let chapter = JobSnapshot.Chapter(
            index: 0, name: "Chapter 0", status: "completed",
            downloadUrl: "file:///restore/chapter-0.mp3", chars: 100, charsProcessed: 100,
            progressRatio: 1, durationSeconds: 10, startedAt: 1, completedAt: 2, textOffset: 0)
        return JobSnapshot(
            jobId: "embedded-\(book)", state: "finished", bookTitle: "Title", bookAuthor: "Author",
            coverUrl: nil, coverMimeType: nil, engine: "piper", voice: "faber", language: "pt-BR",
            progressPercent: 100, chaptersTotal: 1, chaptersCompleted: 1, chapterProgress: [chapter],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: 2,
            chapterIndexBase: 0, sourceChaptersTotal: 1)
    }
}
#endif
