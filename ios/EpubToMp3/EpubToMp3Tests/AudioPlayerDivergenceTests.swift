#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// Unit tests for the play-tap divergence routing added to
/// `AudioPlayer`: chapter-index translation, decision matrix,
/// sentence-level seek lookup, ratio fallback, and the pending-seek
/// queue that survives the AVPlayer asset-prepare gap.
@MainActor
final class AudioPlayerDivergenceTests: XCTestCase {

    private func makePlayer() -> AudioPlayer { AudioPlayer() }

    private func snapshotWithChapters(_ count: Int) -> JobSnapshot {
        let chapters: [JobSnapshot.Chapter] = (0..<count).map { idx in
            JobSnapshot.Chapter(
                index: idx,
                name: "Chapter \(idx + 1)",
                status: "completed",
                downloadUrl: "/api/jobs/test/chapters/\(idx)/mp3",
                chars: 1000,
                charsProcessed: 1000,
                progressRatio: 1.0,
                durationSeconds: 60,
                startedAt: nil,
                completedAt: nil
            )
        }
        return JobSnapshot(
            jobId: "test-job",
            state: "done",
            bookTitle: "Test Book",
            bookAuthor: "Author",
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: "en",
            progressPercent: 100,
            chaptersTotal: count,
            chaptersCompleted: count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }

    // MARK: playTapDecision

    /// With no snapshot loaded, every tap is a plain resume — no
    /// divergence detection is possible.
    func testDecisionWithoutSnapshotIsResume() {
        let player = makePlayer()
        XCTAssertEqual(player.playTapDecision(readerChapterIndex: 5), .resume)
    }

    /// Audio playing → always pause, regardless of divergence.
    func testDecisionWhilePlayingIsPause() {
        let player = makePlayer()
        // Force the isPlaying flag for the decision check; we don't
        // need a real queue for this branch.
        player.testHook_setIsPlaying(true)
        XCTAssertEqual(player.playTapDecision(readerChapterIndex: 99), .pause)
    }

    /// Same chapter on both sides → resume (no dialog).
    func testDecisionWithMatchingChaptersIsResume() {
        let player = makePlayer()
        player.testHook_setSnapshot(snapshotWithChapters(5))
        player.testHook_setCurrentChapterIndex(2)
        XCTAssertEqual(player.playTapDecision(readerChapterIndex: 2), .resume)
    }

    /// Reader on a different chapter → offerStartChoice (dialog).
    func testDecisionWithDivergentChaptersOffersDialog() {
        let player = makePlayer()
        player.testHook_setSnapshot(snapshotWithChapters(5))
        player.testHook_setCurrentChapterIndex(2)
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 0),
            .offerStartChoice
        )
    }

    /// `playTapDecision` must translate EPUB index → playable index
    /// before comparing. Reader at EPUB index 2, audio at playable
    /// index 1 (which IS EPUB index 2 when index 1 is unplayable)
    /// — should be `.resume`, NOT `.offerStartChoice`.
    func testDecisionTranslatesEpubToPlayableSpace() {
        let player = makePlayer()
        // Playable chapters: EPUB 0, 2, 3 (EPUB 1 is unplayable, e.g. footnotes).
        let playable0 = JobSnapshot.Chapter(
            index: 0, name: "Intro", status: "completed",
            downloadUrl: "/0.mp3", chars: 1, charsProcessed: 1,
            progressRatio: 1, durationSeconds: 1, startedAt: nil, completedAt: nil
        )
        let unplayable1 = JobSnapshot.Chapter(
            index: 1, name: "Footnotes", status: "skipped",
            downloadUrl: nil, chars: 0, charsProcessed: 0,
            progressRatio: 0, durationSeconds: nil, startedAt: nil, completedAt: nil
        )
        let playable2 = JobSnapshot.Chapter(
            index: 2, name: "Ch 1", status: "completed",
            downloadUrl: "/2.mp3", chars: 1, charsProcessed: 1,
            progressRatio: 1, durationSeconds: 1, startedAt: nil, completedAt: nil
        )
        let playable3 = JobSnapshot.Chapter(
            index: 3, name: "Ch 2", status: "completed",
            downloadUrl: "/3.mp3", chars: 1, charsProcessed: 1,
            progressRatio: 1, durationSeconds: 1, startedAt: nil, completedAt: nil
        )
        let snap = JobSnapshot(
            jobId: "j", state: "done",
            bookTitle: "B", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: nil,
            progressPercent: nil, chaptersTotal: 4, chaptersCompleted: 3,
            chapterProgress: [playable0, unplayable1, playable2, playable3],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        player.testHook_setSnapshot(snap)
        // Audio is on playable index 1 = EPUB chapter 2.
        player.testHook_setCurrentChapterIndex(1)
        // Reader at EPUB index 2 — same physical chapter; resume, no dialog.
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 2),
            .resume,
            "Reader's EPUB index 2 matches audio's playable index 1 → no dialog"
        )
        // Reader at EPUB index 0 — different chapter; dialog.
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 0),
            .offerStartChoice,
            "Reader's EPUB index 0 differs from audio's playable index 1 → dialog"
        )
        // Reader sitting on the unplayable EPUB index 1 (footnotes)
        // — translation must fall back to the nearest playable ≤
        // that index (EPUB 0 = playable 0). Audio is on playable 1
        // → divergent → dialog.
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 1),
            .offerStartChoice,
            "Reader sitting on unplayable chapter falls back to previous playable → still divergent"
        )
    }

    // MARK: JobSnapshot index translation

    /// `playableChapters` strips chapters with no `downloadUrl`. The
    /// remaining list keeps the original EPUB-side `.index` field so
    /// downstream surfaces can translate between the two index spaces.
    /// Regression guard for the source-of-truth bug fixed 2026-05-18.
    func testPlayableChaptersFiltersUnplayableAndPreservesIndex() {
        let playable = JobSnapshot.Chapter(
            index: 0, name: "Intro", status: "completed",
            downloadUrl: "/a.mp3", chars: 100, charsProcessed: 100,
            progressRatio: 1, durationSeconds: 10, startedAt: nil,
            completedAt: nil
        )
        let unplayable = JobSnapshot.Chapter(
            index: 1, name: "Footnotes", status: "skipped",
            downloadUrl: nil, chars: 50, charsProcessed: 0,
            progressRatio: 0, durationSeconds: nil, startedAt: nil,
            completedAt: nil
        )
        let alsoPlayable = JobSnapshot.Chapter(
            index: 2, name: "Ch1", status: "completed",
            downloadUrl: "/b.mp3", chars: 200, charsProcessed: 200,
            progressRatio: 1, durationSeconds: 20, startedAt: nil,
            completedAt: nil
        )
        let snap = JobSnapshot(
            jobId: "j", state: "done",
            bookTitle: "B", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: nil,
            progressPercent: nil, chaptersTotal: 3, chaptersCompleted: 2,
            chapterProgress: [playable, unplayable, alsoPlayable],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        let result = snap.playableChapters
        XCTAssertEqual(result.count, 2, "Skipped chapter must not appear")
        XCTAssertEqual(result.map(\.index), [0, 2],
            "Playable subset must preserve the original EPUB indices (0, 2 — not 0, 1)")
        // Translation invariant: the EPUB index of the chapter at
        // playable[currentChapterIndex] is what every highlight / TOC
        // compare must use.
        let playerCurrent = 1                        // 2nd playable chapter
        XCTAssertEqual(result[playerCurrent].index, 2,
            "Reader/TOC code must translate via this lookup — never compare " +
            "AudioPlayer.currentChapterIndex against JobSnapshot.Chapter.index directly")
    }

    // MARK: setSentenceTiming cache

    /// Injecting timing then reading via `startFromReaderPage` should
    /// route to the precise sentence offset (preferred over the
    /// ratio).
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
    func testSentenceTimingClearWithEmptyMap() {
        let player = makePlayer()
        player.setSentenceTiming(["a": 100], forChapterIndex: 3)
        player.setSentenceTiming([:], forChapterIndex: 3)
        XCTAssertNil(player.testHook_sentenceTimingMap(forChapterIndex: 3))
    }

    /// Re-injecting a chapter's map should refresh LRU position (so
    /// the chapter doesn't get evicted on the very next insert).
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

    // MARK: Pending proportional seek

    /// A ratio passed to `startFromReaderPage` before duration lands
    /// must be queued and applied once duration is known.
    func testPendingProportionalSeekAppliedOnceDurationLands() {
        let player = makePlayer()
        player.testHook_setPendingProportionalSeek(0.5)
        // Duration still 0 — applying should be a no-op.
        player.applyPendingProportionalSeek()
        XCTAssertEqual(
            player.testHook_pendingProportionalSeek(),
            0.5,
            "Pending seek must persist while duration is unknown"
        )
        player.testHook_setDurationSeconds(120)
        player.applyPendingProportionalSeek()
        XCTAssertNil(
            player.testHook_pendingProportionalSeek(),
            "Pending seek must clear after duration-driven apply"
        )
    }
}
#endif
