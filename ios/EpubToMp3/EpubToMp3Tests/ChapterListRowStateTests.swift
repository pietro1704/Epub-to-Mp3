#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
@testable import EpubToMp3

final class ChapterListRowStateTests: XCTestCase {
    func testCurrentRowUsesEpubIndexFromPlayableCursor() {
        let chapters = [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
            Self.playableChapter(index: 2),
            Self.playableChapter(index: 4),
        ]
        let snapshot = Self.snapshot(chapters: chapters)

        let state = ChapterListRowState.resolve(
            chapter: chapters[2],
            snapshot: snapshot,
            currentPlayableIndex: 1
        )

        XCTAssertTrue(state.isCurrent)
        XCTAssertEqual(state.playableIndex, 1)
    }

    func testUnplayableRowHasNoPlayableIndexAndIsNotCurrent() {
        let chapters = [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
            Self.playableChapter(index: 2),
        ]
        let snapshot = Self.snapshot(chapters: chapters)

        let state = ChapterListRowState.resolve(
            chapter: chapters[1],
            snapshot: snapshot,
            currentPlayableIndex: 1
        )

        XCTAssertFalse(state.isCurrent)
        XCTAssertNil(state.playableIndex)
        XCTAssertFalse(state.isPlayable)
    }

    private static func snapshot(chapters: [JobSnapshot.Chapter]) -> JobSnapshot {
        JobSnapshot(
            jobId: "chapter-list-row-state",
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
