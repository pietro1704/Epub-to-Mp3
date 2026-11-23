import XCTest
#if SWIFT_PACKAGE
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class ListeningJobSnapshotTests: XCTestCase {
    func testPendingSnapshotKeepsEmptyAndSeededChapterCatalogs() {
        let pendingChapter = JobSnapshot.Chapter(
            index: 4, name: "Chapter five", status: "pending", downloadUrl: nil,
            chars: 120, charsProcessed: nil, progressRatio: nil, durationSeconds: nil,
            startedAt: nil, completedAt: nil
        )

        for chapters in [[], [pendingChapter]] {
            let snapshot = JobSnapshot.listeningPending(
                jobID: "pending-job", bookTitle: "Book", bookAuthor: "Author", chapters: chapters
            )

            XCTAssertEqual(snapshot.id, "pending-job")
            XCTAssertEqual(snapshot.state, "running")
            XCTAssertEqual(snapshot.bookTitle, "Book")
            XCTAssertEqual(snapshot.bookAuthor, "Author")
            XCTAssertNil(snapshot.coverUrl)
            XCTAssertNil(snapshot.coverMimeType)
            XCTAssertNil(snapshot.engine)
            XCTAssertNil(snapshot.voice)
            XCTAssertNil(snapshot.language)
            XCTAssertEqual(snapshot.progressPercent, 0)
            XCTAssertNil(snapshot.chaptersTotal)
            XCTAssertEqual(snapshot.chaptersCompleted, 0)
            XCTAssertEqual(snapshot.chapterProgress, chapters)
            XCTAssertEqual(snapshot.chapterIndexBase, 0)
            XCTAssertNil(snapshot.sourceChaptersTotal)
            XCTAssertNil(snapshot.outputs)
            XCTAssertNil(snapshot.logUrl)
            XCTAssertNil(snapshot.error)
            XCTAssertNotNil(snapshot.lastActivityAt)
        }
    }

    func testFailedSnapshotKeepsListeningJobIdentityAndProgress() {
        let chapter = JobSnapshot.Chapter(
            index: 4, name: "Chapter five", status: "completed", downloadUrl: "chapter.mp3",
            chars: 120, charsProcessed: 120, progressRatio: 1, durationSeconds: 8,
            startedAt: 2, completedAt: 3, textOffset: 20
        )
        var running = JobSnapshot(
            jobId: "partial-job", state: "running",
            bookTitle: "Book", bookAuthor: "Author", coverUrl: "cover.png", coverMimeType: "image/png",
            engine: "piper", voice: "pt_BR-faber-medium", language: "pt-BR",
            progressPercent: 33.3, chaptersTotal: 3, chaptersCompleted: 1, chapterProgress: [chapter],
            outputs: [.init(name: "chapter.mp3", url: "chapter.mp3", sizeBytes: 8)], logUrl: "conversion.log",
            error: "Previous message", lastActivityAt: 1, chapterIndexBase: 0, sourceChaptersTotal: 10
        )

        let failed = running.failed(error: "Narration failed")

        XCTAssertEqual(failed.id, running.id)
        XCTAssertEqual(failed.state, "failed")
        XCTAssertEqual(failed.bookTitle, running.bookTitle)
        XCTAssertEqual(failed.bookAuthor, running.bookAuthor)
        XCTAssertEqual(failed.coverUrl, running.coverUrl)
        XCTAssertEqual(failed.coverMimeType, running.coverMimeType)
        XCTAssertEqual(failed.engine, running.engine)
        XCTAssertEqual(failed.voice, running.voice)
        XCTAssertEqual(failed.language, running.language)
        XCTAssertEqual(failed.progressPercent, running.progressPercent)
        XCTAssertEqual(failed.chaptersTotal, running.chaptersTotal)
        XCTAssertEqual(failed.chaptersCompleted, running.chaptersCompleted)
        XCTAssertEqual(failed.chapterProgress, running.chapterProgress)
        XCTAssertEqual(failed.chapterIndexBase, running.chapterIndexBase)
        XCTAssertEqual(failed.sourceChaptersTotal, running.sourceChaptersTotal)
        XCTAssertEqual(failed.isCompleteBookAudio, false)
        XCTAssertEqual(failed.outputs, running.outputs)
        XCTAssertEqual(failed.logUrl, running.logUrl)
        XCTAssertEqual(failed.error, "Narration failed")
        XCTAssertGreaterThan(failed.lastActivityAt ?? 0, running.lastActivityAt ?? 0)

        running.chapterIndexBase = nil
        running.sourceChaptersTotal = nil
        let failedWithoutCoverage = running.failed(error: "Narration failed")
        XCTAssertNil(failedWithoutCoverage.chapterIndexBase)
        XCTAssertNil(failedWithoutCoverage.sourceChaptersTotal)
    }
}
