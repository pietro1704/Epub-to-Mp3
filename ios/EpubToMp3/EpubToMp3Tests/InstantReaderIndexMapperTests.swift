#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
@testable import EpubToMp3

final class InstantReaderIndexMapperTests: XCTestCase {
    func testTocJumpTranslatesEpubIndexToPlayableIndex() {
        let snapshot = Self.snapshot(chapters: [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
            Self.playableChapter(index: 2),
            Self.pendingChapter(index: 3),
            Self.playableChapter(index: 4),
        ])

        XCTAssertEqual(
            InstantReaderIndexMapper.playableIndex(forEpubIndex: 2, in: snapshot),
            1,
            "chapter taps provide EPUB-zero-based indices; AudioPlayer.play(startingAt:) expects playable-list indices"
        )
    }

    func testMountedPlayerSyncTranslatesPlayableIndexBackToEpubIndex() {
        let snapshot = Self.snapshot(chapters: [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
            Self.playableChapter(index: 2),
            Self.playableChapter(index: 4),
        ])

        XCTAssertEqual(
            InstantReaderIndexMapper.epubIndex(forPlayableIndex: 1, in: snapshot),
            2,
            "position sync must write EPUB-space into InstantReaderView.currentChapterIndex"
        )
    }

    func testTocJumpCanClampMissingEpubIndexToNearestPlayableSlot() {
        let snapshot = Self.snapshot(chapters: [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
            Self.playableChapter(index: 2),
        ])

        XCTAssertEqual(
            InstantReaderIndexMapper.playableIndexOrClamped(forEpubIndex: 1, in: snapshot),
            1,
            "PlayerReaderView preserves its legacy fallback: skipped EPUB chapter 1 clamps into playable slot 1, not raw EPUB index"
        )
    }

    private static func snapshot(chapters: [JobSnapshot.Chapter]) -> JobSnapshot {
        JobSnapshot(
            jobId: "instant-reader-index-map",
            state: "running",
            bookTitle: "Sparse Book",
            bookAuthor: nil,
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: nil,
            progressPercent: nil,
            chaptersTotal: chapters.count,
            chaptersCompleted: chapters.count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }

    private static func playableChapter(index: Int) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Chapter \(index + 1)",
            status: "completed",
            downloadUrl: "http://example.invalid/ch-\(index).mp3",
            chars: 1234,
            charsProcessed: 1234,
            progressRatio: 1.0,
            durationSeconds: 60,
            startedAt: 0,
            completedAt: 0
        )
    }

    private static func pendingChapter(index: Int) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: "Chapter \(index + 1)",
            status: "pending",
            downloadUrl: nil,
            chars: 1234,
            charsProcessed: 0,
            progressRatio: 0,
            durationSeconds: nil,
            startedAt: nil,
            completedAt: nil
        )
    }
}
#endif
