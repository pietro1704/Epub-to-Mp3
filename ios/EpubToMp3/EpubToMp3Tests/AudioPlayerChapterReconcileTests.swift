import XCTest
@testable import EpubToMp3

/// Regression coverage for the "O Hobbit" now-playing oscillation bug:
/// when two chapters (e.g. cover image + title page) resolve to the exact
/// same `downloadUrl` (both back onto the same cached/near-silent MP3),
/// the lock-screen / Now Playing chapter index must never ping-pong
/// between them as `AVQueuePlayer` advances forward.
final class AudioPlayerChapterReconcileTests: XCTestCase {
    private let coverURL = URL(fileURLWithPath: "/tmp/book/shared-silence.mp3")
    private let titlePageURL = URL(fileURLWithPath: "/tmp/book/shared-silence.mp3")
    private let chapter2URL = URL(fileURLWithPath: "/tmp/book/chapter-2.mp3")
    private let chapter3URL = URL(fileURLWithPath: "/tmp/book/chapter-3.mp3")

    func testDuplicateURLChaptersResolveForwardNotToFirstMatch() {
        // Index 0 = cover, index 1 = title page — both share the same URL.
        let chapterURLs: [URL?] = [coverURL, titlePageURL, chapter2URL, chapter3URL]

        // Queue starts on chapter 0 (cover). Current item is the shared URL —
        // must resolve to index 0 (itself), not jump anywhere.
        XCTAssertEqual(
            AudioPlayer.resolveChapterIndex(currentIndex: 0, chapterURLs: chapterURLs, currentItemURL: coverURL),
            0
        )

        // Queue advances to item 1 (title page), which has the SAME url as
        // chapter 0. A naive `firstIndex(where:)` would resolve this back to
        // 0 (the cover) forever. Searching forward from the current index
        // must keep us at (or move us to) index 1, never snap back to 0.
        XCTAssertEqual(
            AudioPlayer.resolveChapterIndex(currentIndex: 1, chapterURLs: chapterURLs, currentItemURL: titlePageURL),
            1,
            "Resolving the shared URL while already on the later chapter must not snap back to the earlier duplicate."
        )

        // Simulate the oscillation scenario directly: pretend the index is
        // still 0 (e.g. end-of-item notification hasn't incremented it yet)
        // but the queue's current item is actually the title page's item
        // (same URL). Forward-first search from index 0 still finds the
        // nearest (index 0) — which is correct behavior (index unchanged,
        // no bogus jump forward past unrelated chapters).
        XCTAssertEqual(
            AudioPlayer.resolveChapterIndex(currentIndex: 0, chapterURLs: chapterURLs, currentItemURL: titlePageURL),
            0
        )
    }

    func testResolvesForwardAdvanceThroughUniqueChapters() {
        let chapterURLs: [URL?] = [coverURL, titlePageURL, chapter2URL, chapter3URL]

        XCTAssertEqual(
            AudioPlayer.resolveChapterIndex(currentIndex: 1, chapterURLs: chapterURLs, currentItemURL: chapter2URL),
            2
        )
        XCTAssertEqual(
            AudioPlayer.resolveChapterIndex(currentIndex: 2, chapterURLs: chapterURLs, currentItemURL: chapter3URL),
            3
        )
    }

    func testReturnsNilWhenNoChapterMatchesCurrentItem() {
        let chapterURLs: [URL?] = [coverURL, chapter2URL]
        let unrelated = URL(fileURLWithPath: "/tmp/book/unknown.mp3")

        XCTAssertNil(AudioPlayer.resolveChapterIndex(currentIndex: 0, chapterURLs: chapterURLs, currentItemURL: unrelated))
    }

    func testReturnsNilWhenCurrentIndexOutOfBounds() {
        let chapterURLs: [URL?] = [coverURL]

        XCTAssertNil(AudioPlayer.resolveChapterIndex(currentIndex: 5, chapterURLs: chapterURLs, currentItemURL: coverURL))
    }

    func testNilChapterURLsAreSkippedWithoutCrashing() {
        // A chapter whose downloadUrl failed to resolve (nil) must never
        // match and must not crash the forward/wrap search.
        let chapterURLs: [URL?] = [nil, chapter2URL]

        XCTAssertEqual(
            AudioPlayer.resolveChapterIndex(currentIndex: 0, chapterURLs: chapterURLs, currentItemURL: chapter2URL),
            1
        )
    }
}
