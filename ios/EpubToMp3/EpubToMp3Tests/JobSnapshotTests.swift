import XCTest
@testable import EpubToMp3

final class JobSnapshotTests: XCTestCase {

    func testDecodesMinimalRunningPayload() throws {
        let json = """
        {
          "jobId": "abc-123",
          "state": "running",
          "bookTitle": "Foundation",
          "progressPercent": 42.5,
          "chaptersTotal": 12,
          "chaptersCompleted": 5,
          "chapterProgress": [
            {"index": 0, "name": "Prologue", "status": "completed",
             "downloadUrl": "/api/outputs/abc-123/prologue.mp3", "progressRatio": 1.0},
            {"index": 1, "name": "Chapter 1", "status": "running", "progressRatio": 0.42}
          ],
          "outputs": [
            {"name": "log.txt", "url": "/api/outputs/abc-123/log.txt", "sizeBytes": 1234}
          ],
          "lastActivityAt": 1715000000.0
        }
        """.data(using: .utf8)!

        let snap = try JSONDecoder().decode(JobSnapshot.self, from: json)
        XCTAssertEqual(snap.jobId, "abc-123")
        XCTAssertEqual(snap.state, "running")
        XCTAssertEqual(snap.bookTitle, "Foundation")
        XCTAssertEqual(snap.progressPercent, 42.5)
        XCTAssertEqual(snap.chapterProgress?.count, 2)
        XCTAssertEqual(snap.chapterProgress?.first?.downloadUrl, "/api/outputs/abc-123/prologue.mp3")
        XCTAssertFalse(snap.isTerminal)
    }

    func testDecodesFinishedPayloadFromRecoveryPath() throws {
        // Mirrors `_restore_job_from_outputs` in python_app/server.py
        let json = """
        {
          "jobId": "rec-1",
          "state": "finished",
          "bookTitle": "Recovered Book",
          "progressPercent": 100.0,
          "chaptersTotal": 3,
          "chaptersCompleted": 3,
          "chapterProgress": [
            {"index": 0, "name": "ch1", "status": "completed",
             "downloadUrl": "/api/outputs/rec-1/ch1.mp3"},
            {"index": 1, "name": "ch2", "status": "completed",
             "downloadUrl": "/api/outputs/rec-1/ch2.mp3"},
            {"index": 2, "name": "ch3", "status": "completed",
             "downloadUrl": "/api/outputs/rec-1/ch3.mp3"}
          ],
          "outputs": [
            {"name": "Recovered Book.zip", "url": "/api/outputs/rec-1/Recovered Book.zip", "sizeBytes": 999}
          ]
        }
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(JobSnapshot.self, from: json)
        XCTAssertTrue(snap.isTerminal)
        XCTAssertEqual(snap.playableChapters.count, 3)
        XCTAssertEqual(snap.playableChapters.first?.displayTitle, "ch1")
    }

    func testDisplayTitleFallbackIsLocalizedWhenNameMissing() throws {
        // The fallback feeds MPMediaItemPropertyTitle (lock screen) — it must
        // go through L10n, never a hardcoded English literal.
        let json = """
        {
          "jobId": "j",
          "state": "running",
          "chapterProgress": [
            {"index": 2, "status": "running"},
            {"index": 3, "name": "", "status": "running"}
          ]
        }
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(JobSnapshot.self, from: json)
        XCTAssertEqual(snap.chapterProgress?[0].displayTitle, L10n.string("player.chapter", 3))
        XCTAssertEqual(snap.chapterProgress?[1].displayTitle, L10n.string("player.chapter", 4))
    }

    func testPlayableChaptersFallsBackToOutputsWhenChapterProgressEmpty() throws {
        let json = """
        {
          "jobId": "j",
          "state": "finished",
          "outputs": [
            {"name": "01.mp3", "url": "/api/outputs/j/01.mp3", "sizeBytes": 100},
            {"name": "02.mp3", "url": "/api/outputs/j/02.mp3", "sizeBytes": 100},
            {"name": "log.txt", "url": "/api/outputs/j/log.txt", "sizeBytes": 50}
          ]
        }
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(JobSnapshot.self, from: json)
        XCTAssertEqual(snap.playableChapters.count, 2)
    }

    func testIgnoresUnknownFields() throws {
        let json = """
        {"jobId": "x", "state": "queued", "futureField": "ignored", "events": ["a", "b"]}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(JobSnapshot.self, from: json)
        XCTAssertEqual(snap.jobId, "x")
    }
}
