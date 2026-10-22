#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation

@testable import EpubToMp3

extension AudioPlayerDivergenceTests {
    @MainActor
    func testEffectiveChapterTitleUsesAudioCursor() {
        let player = makePlayer()
        player.testHook_setSnapshot(snapshotWithChapters(3))
        player.testHook_setCurrentChapterIndex(1)

        XCTAssertEqual(player.effectiveChapterTitle, "Chapter 2")
    }

    /// With no snapshot loaded, every tap is a plain resume — no
    /// divergence detection is possible.
    @MainActor
    func testDecisionWithoutSnapshotIsResume() {
        let player = makePlayer()
        XCTAssertEqual(player.playTapDecision(readerChapterIndex: 5), .resume)
    }

    /// Audio playing → always pause, regardless of divergence.
    @MainActor
    func testDecisionWhilePlayingIsPause() {
        let player = makePlayer()
        // Force the isPlaying flag for the decision check; we don't
        // need a real queue for this branch.
        player.testHook_setIsPlaying(true)
        XCTAssertEqual(player.playTapDecision(readerChapterIndex: 99), .pause)
    }

    /// Same chapter on both sides → resume (no dialog).
    @MainActor
    func testDecisionWithMatchingChaptersIsResume() {
        let player = makePlayer()
        player.testHook_setSnapshot(snapshotWithChapters(5))
        player.testHook_setCurrentChapterIndex(2)
        XCTAssertEqual(player.playTapDecision(readerChapterIndex: 2), .resume)
    }

    /// Reader on a different chapter → offerStartChoice (dialog).
    @MainActor
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
    @MainActor
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

    /// A known reader page is an explicit listener choice. Even within the
    /// same chapter, Play must restart at that page instead of resuming an
    /// older audio cursor.
    @MainActor
    func testDecisionWithSameChapterAndKnownPageStartsFromReaderPage() {
        let player = makePlayer()
        player.testHook_setSnapshot(snapshotWithChapters(5))
        player.testHook_setCurrentChapterIndex(2)
        player.testHook_setDurationSeconds(100)
        player.seek(to: 10)

        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 2, readerPageRatio: 0.7),
            .startFromReaderPage
        )
    }

    /// The page anchor remains authoritative even when it is close to the
    /// previous audio position, avoiding an implicit and surprising resume.
    @MainActor
    func testDecisionWithSameChapterAndNearbyPageStartsFromReaderPage() {
        let player = makePlayer()
        player.testHook_setSnapshot(snapshotWithChapters(5))
        player.testHook_setCurrentChapterIndex(2)
        player.testHook_setDurationSeconds(100)
        player.seek(to: 52)

        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 2, readerPageRatio: 0.55),
            .startFromReaderPage
        )
    }

    @MainActor
    func testPauseThenResumeKeepsTheExistingQueueInsteadOfRestartingFromReaderPage() {
        let player = makePlayer()
        player.backendBaseURL = URL(string: "http://localhost:0/")!
        player.play(snapshot: snapshotWithChapters(3), startingAt: 1)
        player.testHook_setIsPlaying(true)

        player.pause()

        XCTAssertTrue(player.hasPausedPlaybackToResume)
        XCTAssertEqual(player.currentChapterIndex, 1)

        player.resume()

        XCTAssertFalse(player.hasPausedPlaybackToResume)
        XCTAssertEqual(
            player.currentChapterIndex,
            1,
            "Resuming a deliberate pause must retain the loaded chapter queue."
        )
    }

    /// Real end-to-end exercise of `play(snapshot:startingAt:)` →
    /// `playTapDecision` → the index-translation pipeline. Goes
    /// through the public API instead of the test-hook setters so a
    /// regression that leaves `currentChapterIndex` correct but
    /// breaks the EPUB↔playable mapping at construction time gets
    /// caught here.
    @MainActor
    func testPlayThenDecideRespectsTranslatedIndex() {
        let player = makePlayer()
        // EPUB chapters 0..4; index 1 (Footnotes) and 3 (Images) are
        // unplayable. Playable subset is therefore [0, 2, 4].
        let chapters: [JobSnapshot.Chapter] = [
            JobSnapshot.Chapter(
                index: 0, name: "Intro", status: "completed",
                downloadUrl: "/0.mp3", chars: 1, charsProcessed: 1,
                progressRatio: 1, durationSeconds: 1,
                startedAt: nil, completedAt: nil
            ),
            JobSnapshot.Chapter(
                index: 1, name: "Footnotes", status: "skipped",
                downloadUrl: nil, chars: 0, charsProcessed: 0,
                progressRatio: 0, durationSeconds: nil,
                startedAt: nil, completedAt: nil
            ),
            JobSnapshot.Chapter(
                index: 2, name: "Ch 1", status: "completed",
                downloadUrl: "/2.mp3", chars: 1, charsProcessed: 1,
                progressRatio: 1, durationSeconds: 1,
                startedAt: nil, completedAt: nil
            ),
            JobSnapshot.Chapter(
                index: 3, name: "Image gallery", status: "skipped",
                downloadUrl: nil, chars: 0, charsProcessed: 0,
                progressRatio: 0, durationSeconds: nil,
                startedAt: nil, completedAt: nil
            ),
            JobSnapshot.Chapter(
                index: 4, name: "Ch 2", status: "completed",
                downloadUrl: "/4.mp3", chars: 1, charsProcessed: 1,
                progressRatio: 1, durationSeconds: 1,
                startedAt: nil, completedAt: nil
            ),
        ]
        let snap = JobSnapshot(
            jobId: "behave-job",
            state: "done",
            bookTitle: "Behaviour Test Book",
            bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: nil,
            progressPercent: nil, chaptersTotal: 5, chaptersCompleted: 3,
            chapterProgress: chapters,
            outputs: nil, logUrl: nil, error: nil,
            lastActivityAt: nil
        )

        // Drive the FULL play path (rather than `testHook_setSnapshot`)
        // so the snapshot lands through the production code path that
        // populates `playableChapters` lazily AND advances the queue
        // head. We give the player a base URL so the relative
        // `downloadUrl` strings resolve — without that, `play()`
        // early-returns on `items.isEmpty` and `currentChapterIndex`
        // stays at 0. The URL doesn't need to point at a real server;
        // AVPlayerItem just needs a syntactically valid asset.
        player.backendBaseURL = URL(string: "http://localhost:0/")!
        player.play(snapshot: snap, startingAt: 1) // playable index 1 = EPUB 2
        XCTAssertEqual(player.currentChapterIndex, 1,
            "play() should land on the playable index we asked for")

        // Reader sitting on EPUB index 2 — same physical chapter the
        // audio is on (translated through playable[1].index == 2).
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 2),
            .resume,
            "Reader EPUB 2 == playing playable 1 (EPUB 2). No dialog."
        )
        // Reader on EPUB 4 — divergent.
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 4),
            .offerStartChoice,
            "Reader EPUB 4 != playing EPUB 2. Dialog."
        )
        // Reader on EPUB 1 (the footnote — unplayable). The
        // translator should fall back to the previous playable
        // (EPUB 0 = playable 0), which still differs from the
        // player's playable 1 → divergence.
        XCTAssertEqual(
            player.playTapDecision(readerChapterIndex: 1),
            .offerStartChoice,
            "Reader on unplayable EPUB 1 → falls back to playable 0 → still divergent"
        )
    }
}
#endif
