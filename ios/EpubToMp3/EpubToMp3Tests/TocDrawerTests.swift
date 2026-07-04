import XCTest
@testable import EpubToMp3

final class TocDrawerTests: XCTestCase {
    func testDownloadableChapterIsDetectedByEpubZeroBasedIndex() {
        let snapshot = Self.snapshot(chapters: [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
            Self.playableChapter(index: 3),
        ])

        XCTAssertTrue(
            TocDrawer.isDownloadAvailable(forEpubZeroBasedIndex: 0, in: snapshot),
            "A chapter with a downloadUrl must be downloadable from the TOC."
        )
        XCTAssertFalse(
            TocDrawer.isDownloadAvailable(forEpubZeroBasedIndex: 1, in: snapshot),
            "Sparse playable chapters must not make a pending EPUB chapter look downloadable."
        )
        XCTAssertTrue(
            TocDrawer.isDownloadAvailable(forEpubZeroBasedIndex: 3, in: snapshot),
            "The TOC callback contract is EPUB zero-based, not playable-list based."
        )
    }

    func testDownloadableChapterLookupReturnsMatchingSnapshotChapter() {
        let snapshot = Self.snapshot(chapters: [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
            Self.playableChapter(index: 2),
        ])

        let match = TocDrawer.downloadableChapter(forEpubZeroBasedIndex: 2, in: snapshot)
        XCTAssertEqual(match?.index, 2)
        XCTAssertEqual(match?.downloadUrl, "http://example.invalid/ch-2.mp3")
    }

    func testDownloadableChapterLookupReturnsNilForPendingChapter() {
        let snapshot = Self.snapshot(chapters: [
            Self.playableChapter(index: 0),
            Self.pendingChapter(index: 1),
        ])

        XCTAssertNil(
            TocDrawer.downloadableChapter(forEpubZeroBasedIndex: 1, in: snapshot),
            "Pending chapters without downloadUrl must not expose a fake TOC download action."
        )
    }

    private static func snapshot(chapters: [JobSnapshot.Chapter]) -> JobSnapshot {
        JobSnapshot(
            jobId: "toc-drawer-test",
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
