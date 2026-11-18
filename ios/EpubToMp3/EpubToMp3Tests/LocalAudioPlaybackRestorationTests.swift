import Foundation
import XCTest
#if APP_FOUNDATION_HOST_TESTS
@testable import AppFoundation
#else
@testable import EpubToMp3
#endif

final class LocalAudioPlaybackRestorationTests: XCTestCase {
    func testPartialRetainedImportKeepsEveryConvertedChapterAndCurrentMetadata() throws {
        let retained = snapshot(job: "embedded-book", chapters: [chapter(0, prefix: "old"), chapter(2)])
        let converted = snapshot(job: "job", chapters: [chapter(0), chapter(1)], total: 3)
        let result = try XCTUnwrap(restore(retained, converted))
        XCTAssertEqual(result.playableChapters.map(\.index), [0, 1, 2])
        XCTAssertEqual(result.playableChapters[0], converted.playableChapters[0])
        XCTAssertEqual(result.playableChapters[2], retained.playableChapters[1])
        XCTAssertEqual(result.jobId, "job")
        XCTAssertEqual(result.engine, converted.engine)
        XCTAssertEqual(result.coverUrl, converted.coverUrl)
        XCTAssertEqual(result.isCompleteBookAudio, true)
        XCTAssertEqual(result.state, "finished")
        XCTAssertEqual(result.progressPercent, 100)
    }

    func testSuffixKeepsItsOffsetAndCannotClaimCompleteBookAudio() throws {
        let retained = snapshot(job: "embedded-book", chapters: [chapter(0, prefix: "old")])
        let suffix = chapter(0, offset: 400)
        let converted = snapshot(job: "job", chapters: [suffix], total: 1)
        let result = try XCTUnwrap(restore(retained, converted))
        XCTAssertEqual(result.playableChapters, [suffix])
        XCTAssertEqual(result.isCompleteBookAudio, false)
        XCTAssertEqual(result.state, "finished")
        XCTAssertTrue(result.isTerminal)
        XCTAssertEqual(result.chaptersCompleted, 0)
    }

    func testUnknownLegacyIndexAxisDoesNotMergeUnprovenChapterIdentities() {
        let retained = snapshot(job: "embedded-book", chapters: [chapter(0)])
        let legacy = snapshot(job: "job", chapters: [chapter(1)], base: nil)
        XCTAssertEqual(restore(retained, legacy), legacy)
    }

    func testOtherBookAndOtherJobCannotEnterRestoredQueue() {
        let retained = snapshot(job: "embedded-book", chapters: [chapter(0)])
        let converted = snapshot(job: "job", chapters: [chapter(1)])
        XCTAssertEqual(restore(snapshot(job: "embedded-other", chapters: [chapter(2)]), converted), converted)
        XCTAssertEqual(restore(retained, snapshot(job: "other-job", chapters: [chapter(2)])), retained)
        XCTAssertNil(LocalAudioPlaybackRestoration.snapshot(
            bookID: "other", conversionJobID: "other-job", retained: retained, converted: converted))
    }

    func testAmbiguousAndNegativeIndicesCannotMerge() {
        let converted = snapshot(job: "job", chapters: [chapter(1)])
        for chapters in [[chapter(0), chapter(0)], [chapter(-1)]] {
            XCTAssertEqual(restore(snapshot(job: "embedded-book", chapters: chapters), converted), converted)
        }
        let retained = snapshot(job: "embedded-book", chapters: [chapter(0)])
        let ambiguous = snapshot(job: "job", chapters: [chapter(1), chapter(1)])
        XCTAssertEqual(restore(retained, ambiguous), ambiguous)
    }

    func testAbsentJobRestoresRetainedAudioWithoutGuessingCompleteness() {
        let retained = snapshot(job: "embedded-book", chapters: [chapter(4)])
        let result = LocalAudioPlaybackRestoration.snapshot(
            bookID: "book", conversionJobID: nil, retained: retained, converted: nil)
        XCTAssertEqual(result, retained)
        XCTAssertNil(result?.isCompleteBookAudio)
        XCTAssertNil(restore(nil, nil))
    }

    func testRetainedChapterOutsideKnownSourceCannotExtendTheQueue() throws {
        let retained = snapshot(job: "embedded-book", chapters: [chapter(9)])
        let converted = snapshot(job: "job", chapters: [chapter(0)], total: 1)
        let result = try XCTUnwrap(restore(retained, converted))
        XCTAssertEqual(result.playableChapters, converted.playableChapters)
        XCTAssertEqual(result.chaptersCompleted, 1)
        XCTAssertEqual(result.progressPercent, 100)
        XCTAssertTrue(result.isTerminal)
    }

    private func restore(_ retained: JobSnapshot?, _ converted: JobSnapshot?) -> JobSnapshot? {
        LocalAudioPlaybackRestoration.snapshot(
            bookID: "book", conversionJobID: "job", retained: retained, converted: converted)
    }

    private func chapter(_ index: Int, prefix: String = "current", offset: Int = 0) -> JobSnapshot.Chapter {
        .init(index: index, name: "Chapter \(index)", status: "completed",
              downloadUrl: "file:///\(prefix)/chapter-\(index).mp3", chars: 100,
              charsProcessed: 100, progressRatio: 1, durationSeconds: 10,
              startedAt: 1, completedAt: 2, textOffset: offset)
    }

    private func snapshot(job: String, chapters: [JobSnapshot.Chapter], total: Int? = nil, base: Int? = 0) -> JobSnapshot {
        .init(jobId: job, state: "finished", bookTitle: "Title", bookAuthor: "Author",
              coverUrl: "file:///cover.png", coverMimeType: "image/png", engine: "piper",
              voice: "faber", language: "pt-BR", progressPercent: 100,
              chaptersTotal: chapters.count, chaptersCompleted: chapters.count,
              chapterProgress: chapters, outputs: nil, logUrl: nil, error: nil,
              lastActivityAt: 2, chapterIndexBase: base, sourceChaptersTotal: total)
    }
}
