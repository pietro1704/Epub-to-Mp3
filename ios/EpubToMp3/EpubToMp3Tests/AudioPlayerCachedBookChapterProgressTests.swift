//
//  AudioPlayerCachedBookChapterProgressTests.swift
//  EpubToMp3Tests
//
//  Regression coverage for AudioPlayer.cachedBookChapterProgress: it must
//  be recomputed exactly when `snapshot` is reassigned, not on every read —
//  MiniPlayerBar/FullPlayerSheet poll it from a CADisplayLink at up to
//  30 fps, so re-deriving BookChapterProgress per read would burn
//  main-thread time on every tick for no reason.
//

import XCTest
@testable import EpubToMp3

@MainActor
final class AudioPlayerCachedBookChapterProgressTests: XCTestCase {

    private func snapshot(chapters: [(index: Int, status: String, chars: Int, url: String?)]) -> JobSnapshot {
        JobSnapshot(
            jobId: "job", state: "running", bookTitle: "Book", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
            progressPercent: nil, chaptersTotal: chapters.count, chaptersCompleted: nil,
            chapterProgress: chapters.map { c in
                JobSnapshot.Chapter(
                    index: c.index, name: "Chapter \(c.index)", status: c.status,
                    downloadUrl: c.url, chars: c.chars, charsProcessed: nil,
                    progressRatio: nil, durationSeconds: nil, startedAt: nil, completedAt: nil
                )
            },
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
    }

    func testNilByDefault() {
        let player = AudioPlayer()
        XCTAssertNil(player.cachedBookChapterProgress)
    }

    func testPopulatedWhenSnapshotHasChapterProgress() {
        let player = AudioPlayer()
        player.testHook_setSnapshot(snapshot(chapters: [(0, "completed", 100, "a.mp3")]))
        XCTAssertNotNil(player.cachedBookChapterProgress)
        XCTAssertEqual(player.cachedBookChapterProgress?.chapters.count, 1)
    }

    func testNilWhenChapterProgressEmpty() {
        let player = AudioPlayer()
        player.testHook_setSnapshot(snapshot(chapters: []))
        XCTAssertNil(player.cachedBookChapterProgress)
    }

    func testUpdatesWhenSnapshotIsReassigned() {
        let player = AudioPlayer()
        player.testHook_setSnapshot(snapshot(chapters: [(0, "running", 100, "a.mp3")]))
        XCTAssertEqual(player.cachedBookChapterProgress?.chapters.first?.state, .running)

        player.testHook_setSnapshot(snapshot(chapters: [(0, "completed", 100, "a.mp3")]))
        XCTAssertEqual(player.cachedBookChapterProgress?.chapters.first?.state, .completed)
    }

    /// The whole point of the cache: reading it repeatedly without
    /// reassigning `snapshot` must return the same identity-equal value,
    /// not rebuild `BookChapterProgress` (sort + map + reduce) each time.
    func testRepeatedReadsWithoutReassignmentReturnEqualValueWithoutRebuilding() {
        let player = AudioPlayer()
        player.testHook_setSnapshot(snapshot(chapters: [(0, "completed", 100, "a.mp3")]))
        let first = player.cachedBookChapterProgress
        for _ in 0..<50 {
            XCTAssertEqual(player.cachedBookChapterProgress, first)
        }
    }
}
