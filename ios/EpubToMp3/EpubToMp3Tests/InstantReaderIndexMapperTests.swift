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

    func testChapterLookupExactMatchOnOneBasedIndex() {
        let fulltext = Self.fulltext(indices: [1, 2, 3])
        let ch = InstantReaderIndexMapper.chapter(in: fulltext, atZeroBasedIndex: 1)
        XCTAssertEqual(ch?.index, 2, "zero-based 1 maps to one-based 2")
    }

    func testChapterLookupFallsBackToPositionalWhenIndexMissing() {
        // backend skipped chapter.index = 2, but the array still has
        // 3 entries — positional fallback should land on slot 1.
        let fulltext = Self.fulltext(indices: [1, 3, 5])
        let ch = InstantReaderIndexMapper.chapter(in: fulltext, atZeroBasedIndex: 1)
        XCTAssertEqual(ch?.index, 3, "no chapter.index == 2 → fall back to positional slot 1")
    }

    func testChapterLookupReturnsNilForNegativeIndex() {
        let fulltext = Self.fulltext(indices: [1, 2, 3])
        XCTAssertNil(
            InstantReaderIndexMapper.chapter(in: fulltext, atZeroBasedIndex: -1),
            "negative index must not subscript-crash even if a caller's ?? -1 fallback leaks through"
        )
    }

    func testChapterLookupReturnsNilForEmptyFulltext() {
        let fulltext = Self.fulltext(indices: [])
        XCTAssertNil(
            InstantReaderIndexMapper.chapter(in: fulltext, atZeroBasedIndex: 0),
            "empty fulltext.chapters must yield nil rather than out-of-bounds subscript"
        )
    }

    func testChapterLookupReturnsNilWhenIndexBeyondArray() {
        let fulltext = Self.fulltext(indices: [1, 2])
        XCTAssertNil(
            InstantReaderIndexMapper.chapter(in: fulltext, atZeroBasedIndex: 5),
            "out-of-range zero-based index must not subscript-crash"
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

    private static func fulltext(indices: [Int]) -> EbookFulltext {
        let chapters: [EbookFulltext.Chapter] = indices.enumerated().map { (slot, idx) in
            EbookFulltext.Chapter(
                index: idx,
                name: "Chapter \(idx)",
                text: "Body of chapter \(idx) at slot \(slot).",
                html: nil,
                css: nil,
                charCount: nil,
                segments: nil
            )
        }
        return EbookFulltext(
            jobId: "ix-mapper-test",
            bookTitle: "Test",
            bookAuthor: nil,
            chapters: chapters
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
