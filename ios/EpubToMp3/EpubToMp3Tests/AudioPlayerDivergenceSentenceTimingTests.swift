#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerDivergenceTests {
    /// Injecting timing then reading via `startFromReaderPage` should
    /// route to the precise sentence offset (preferred over the
    /// ratio).
    @MainActor
    func testSentenceTimingCacheStoresMostRecentChapters() {
        let player = makePlayer()
        // Populate beyond the cache size (8) — the oldest must be
        // evicted, the most recent must survive.
        for i in 0..<10 {
            player.setSentenceTiming(["s\(i)": i * 1000], forChapterIndex: i)
        }
        XCTAssertNil(
            player.testHook_sentenceTimingMap(forChapterIndex: 0),
            "Chapter 0 should have been evicted past the 8-entry cap"
        )
        XCTAssertEqual(
            player.testHook_sentenceTimingMap(forChapterIndex: 9)?["s9"],
            9000,
            "Most recently inserted chapter must still resolve"
        )
    }

    /// Setting an empty map clears the entry.
    @MainActor
    func testSentenceTimingClearWithEmptyMap() {
        let player = makePlayer()
        player.setSentenceTiming(["a": 100], forChapterIndex: 3)
        player.setSentenceTiming([:], forChapterIndex: 3)
        XCTAssertNil(player.testHook_sentenceTimingMap(forChapterIndex: 3))
    }

    /// Re-injecting a chapter's map should refresh LRU position (so
    /// the chapter doesn't get evicted on the very next insert).
    @MainActor
    func testSentenceTimingReinjectionRefreshesLRU() {
        let player = makePlayer()
        // Fill the cache exactly.
        for i in 0..<8 {
            player.setSentenceTiming(["s\(i)": i], forChapterIndex: i)
        }
        // Re-touch chapter 0 → moves it to the most-recent slot.
        player.setSentenceTiming(["s0-new": 99], forChapterIndex: 0)
        // Insert one more — chapter 1 (not 0) should be evicted.
        player.setSentenceTiming(["s8": 800], forChapterIndex: 8)
        XCTAssertNotNil(
            player.testHook_sentenceTimingMap(forChapterIndex: 0),
            "Chapter 0 was re-touched and must survive eviction"
        )
        XCTAssertNil(
            player.testHook_sentenceTimingMap(forChapterIndex: 1),
            "Chapter 1 was oldest after re-touch and should be evicted"
        )
    }

    @MainActor
    func testSentenceWordOffsetAdvancesWithinSentenceTimingWindow() {
        XCTAssertEqual(
            ReaderPlaybackSeek.sentenceStartMs(
                startMs: 1_000,
                nextStartMs: 3_000,
                offsetRatio: 0.5
            ),
            2_000,
            accuracy: 0.001
        )
    }
}
#endif
