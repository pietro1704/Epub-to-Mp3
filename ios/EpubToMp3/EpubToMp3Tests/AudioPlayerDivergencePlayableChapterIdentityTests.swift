#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerDivergenceTests {
    /// Regression: in the embedded-runtime path, chapters arrive via
    /// `enqueueSegment` and the snapshot carries no `downloadUrl`s,
    /// so `playableChapters` is permanently empty. Pre-fix,
    /// `playTapDecision` returned `.offerStartChoice` (translation
    /// returned nil → fall-through to the divergence dialog); picking
    /// any option called `play(snapshot:)` which then teardown the
    /// live queue and refused to rebuild it (no URLs). User-visible
    /// symptom: "diz que baixou todos os caps mas não toca nada (pede
    /// pra baixar)". Now the decision short-circuits to `.resume` when
    /// segment mode is live, so the existing queue plays.
    @MainActor
    func testDecisionInSegmentModeWithEmptyPlayableChaptersIsResume() {
        let player = makePlayer()
        // Empty snapshot — `playableChapters` is [].
        let empty = JobSnapshot(
            jobId: "embedded-job", state: "converting",
            bookTitle: "B", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: nil,
            progressPercent: nil, chaptersTotal: 5, chaptersCompleted: 0,
            chapterProgress: nil, outputs: nil, logUrl: nil,
            error: nil, lastActivityAt: nil
        )
        XCTAssertTrue(empty.playableChapters.isEmpty)
        player.testHook_setSnapshot(empty)
        player.testHook_simulateSegmentMode()
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 0),
            .resume,
            "Embedded segment mode has nothing for the divergence dialog to resolve — taps must resume"
        )
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 99),
            .resume,
            "Any reader chapter index must still resume — there's no playable list to compare against"
        )
    }

    @MainActor
    func testSegmentStreamDoesNotAppendCompletedChapterAudioTwice() {
        let player = makePlayer()
        let pending = JobSnapshot(
            jobId: "streaming-job", state: "running",
            bookTitle: "B", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: nil,
            progressPercent: 0, chaptersTotal: 1, chaptersCompleted: 0,
            chapterProgress: [
                .init(
                    index: 0, name: "Chapter 1", status: "processing",
                    downloadUrl: nil, chars: 1, charsProcessed: 0,
                    progressRatio: 0, durationSeconds: nil,
                    startedAt: nil, completedAt: nil
                )
            ],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        player.testHook_setSnapshot(pending)
        player.testHook_simulateSegmentMode()

        player.updateSnapshot(snapshotWithChapters(1, jobID: "streaming-job"))

        XCTAssertEqual(
            player.testHook_playbackChapterCount(), 0,
            "A completed chapter must not be appended while its segments already own the queue"
        )
    }

    /// Embedded playback queues files named `ch<N>-seg<M>.mp3`. The chapter
    /// shown by the player must follow AVQueuePlayer.currentItem, not the
    /// most recently enqueued buffer-ahead segment.
    @MainActor
    func testSegmentItemURLResolvesItsChapterIndex() {
        XCTAssertEqual(
            PlaybackSegmentSession.chapterIndexForSegmentItem(URL(fileURLWithPath: "/tmp/ch12-seg3.mp3")),
            12
        )
        XCTAssertNil(
            PlaybackSegmentSession.chapterIndexForSegmentItem(URL(fileURLWithPath: "/tmp/not-a-segment.mp3"))
        )
    }

    /// `playableChapters` strips chapters with no `downloadUrl`. The
    /// remaining list keeps the original EPUB-side `.index` field so
    /// downstream surfaces can translate between the two index spaces.
    /// Regression guard for the source-of-truth bug fixed 2026-05-18.
    @MainActor
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
}
#endif
