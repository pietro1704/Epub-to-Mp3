import XCTest
@testable import EpubToMp3

final class BookChapterProgressTests: XCTestCase {
    func testOrdersAllRawChaptersIncludingNonPlayableSparseIndices() {
        let model = BookChapterProgress(snapshot: snapshot(chapters: [
            chapter(index: 5, status: "queued", url: nil, chars: 100),
            chapter(index: 1, status: "completed", url: "/one.mp3", chars: 200),
            chapter(index: 3, status: "failed", url: nil, chars: 300)
        ]))

        XCTAssertEqual(model.chapters.map(\.epubIndex), [1, 3, 5])
        XCTAssertEqual(model.chapters.map(\.isPlayable), [true, false, false])
    }

    func testDerivesStateAndClampsRatioWithCharacterFallback() {
        let model = BookChapterProgress(snapshot: snapshot(chapters: [
            chapter(index: 0, status: "completed", url: "/one.mp3", ratio: 1.4, chars: 100),
            chapter(index: 1, status: "running", url: "/two.mp3", ratio: -0.2, chars: 100),
            chapter(index: 2, status: nil, url: nil, chars: 100, processed: 25),
            chapter(index: 3, status: "failed", url: nil, chars: 100, processed: 50)
        ]))

        XCTAssertEqual(model.chapters.map(\.state), [.completed, .running, .queued, .failed])
        for (actual, expected) in zip(model.chapters.map(\.ratio), [1, 0, 0.25, 0.5]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
    }

    func testWeightedOverallProgressUsesChapterSizes() {
        let model = BookChapterProgress(snapshot: snapshot(chapters: [
            chapter(index: 0, status: "running", url: "/one.mp3", ratio: 0.5, chars: 100),
            chapter(index: 1, status: "completed", url: "/two.mp3", ratio: 1, chars: 300)
        ]))

        XCTAssertEqual(model.overallRatio, 0.875, accuracy: 0.0001)
    }

    func testMapsEPUBIndicesToPlayableOrderForHighlighting() {
        let model = BookChapterProgress(snapshot: snapshot(chapters: [
            chapter(index: 0, status: "completed", url: "/one.mp3", chars: 100),
            chapter(index: 2, status: "queued", url: nil, chars: 200),
            chapter(index: 4, status: "running", url: "/four.mp3", chars: 300)
        ]))

        XCTAssertEqual(model.playableIndex(forEPUBIndex: 0), 0)
        XCTAssertNil(model.playableIndex(forEPUBIndex: 2))
        XCTAssertEqual(model.playableIndex(forEPUBIndex: 4), 1)
        XCTAssertEqual(model.epubIndex(forPlayableIndex: 1), 4)
    }

    private func snapshot(chapters: [JobSnapshot.Chapter]) -> JobSnapshot {
        JobSnapshot(
            jobId: "job", state: "running", bookTitle: "Book", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
            progressPercent: nil, chaptersTotal: chapters.count, chaptersCompleted: nil,
            chapterProgress: chapters, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
    }

    private func chapter(
        index: Int,
        status: String?,
        url: String?,
        ratio: Double? = nil,
        chars: Int?,
        processed: Int? = nil
    ) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index, name: "Chapter \(index)", status: status, downloadUrl: url,
            chars: chars, charsProcessed: processed, progressRatio: ratio,
            durationSeconds: nil, startedAt: nil, completedAt: nil
        )
    }
}
