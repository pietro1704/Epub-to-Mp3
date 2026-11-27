import XCTest
@testable import EpubToMp3
import Darwin

final class RustConversionCoordinatorTests: XCTestCase {
    func testProgressAndChapterPreserveResolvedVoiceAndRejectForeignJobs() throws {
        func progress(_ engine: String, model: String? = nil, voice: String? = nil, job: String = "active") throws -> RustConversionCoordinator.ConversionProgressEvent {
            var object: [String: Any] = ["jobId": job, "state": "running", "chaptersTotal": 3,
                "chaptersCompleted": 0, "percent": 0, "engine": engine, "message": "Fixture"]
            object["modelId"] = model; object["voice"] = voice
            return try JSONDecoder().decode(RustConversionCoordinator.ConversionProgressEvent.self,
                                           from: JSONSerialization.data(withJSONObject: object))
        }
        let chapter = RustConversionCoordinator.ChapterCompletionEvent(jobId: "active", bookTitle: "Book", bookAuthor: "Author",
            chapterIndex: 0, chaptersTotal: 3, chaptersCompleted: 1, chapterTitle: "Chapter", filename: "one.mp3",
            audioPath: URL(fileURLWithPath: "/fixture/one.mp3"), textChars: 50)
        let initial = chapter.snapshot(chapters: [])
        let primary = try progress("piper", model: "pt_BR-faber-medium").updating(initial)
        let completed = chapter.snapshot(chapters: [chapter.playableChapter], preserving: primary)
        XCTAssertEqual(completed.voice, "pt_BR-faber-medium")
        let unresolvedFallback = try progress("system").updating(completed)
        XCTAssertNil(unresolvedFallback.voice, "System fallback cannot retain the old Piper model as its voice")
        let fallback = try progress("system", voice: "Luciana (installed.luciana)").updating(unresolvedFallback)
        XCTAssertEqual(chapter.snapshot(chapters: [chapter.playableChapter], preserving: fallback).voice,
                       "Luciana (installed.luciana)")
        let recovered = try progress("piper", model: "pt_BR-faber-medium").updating(fallback)
        XCTAssertEqual(recovered.engine, "piper")
        XCTAssertEqual(recovered.voice, "pt_BR-faber-medium")
        XCTAssertEqual(try progress("edge", voice: "foreign", job: "retired").updating(recovered), recovered)
        // A foreign chapter cannot erase or replace the current session.
        let foreign = RustConversionCoordinator.ChapterCompletionEvent(jobId: "retired", bookTitle: "Old", bookAuthor: "Author", chapterIndex: 0,
            chaptersTotal: 1, chaptersCompleted: 1, chapterTitle: "Old", filename: "old.mp3",
            audioPath: URL(fileURLWithPath: "/fixture/old.mp3"), textChars: 1)
        XCTAssertEqual(foreign.snapshot(chapters: [], preserving: recovered), recovered)
    }

    /// The last chapter can finish while the job is still publishing its result.
    func testRunningConversionNeverReportsCompletionBeforeTheResult() {
        let event = RustConversionCoordinator.ChapterCompletionEvent(
            jobId: "active", bookTitle: "Book", bookAuthor: "Author", chapterIndex: 1, chaptersTotal: 2,
            chaptersCompleted: 2, chapterTitle: "Last", filename: "two.mp3",
            audioPath: URL(fileURLWithPath: "/fixture/two.mp3"), textChars: 50)
        XCTAssertEqual(event.progressPercent, 99)
        let running = event.snapshot(chapters: [])
        XCTAssertEqual(running.progressPercent, 99)
    }

    func testEnrichedChapterReportsActualSystemVoiceWithoutPriorProgressDelivery() throws {
        let payload = Data(#"{"jobId":"active","bookTitle":"Book","bookAuthor":"Author","chapterIndex":0,"chaptersTotal":1,"chaptersCompleted":1,"chapterTitle":"Chapter","filename":"one.mp3","audioPath":"/fixture/one.mp3","textChars":50,"engine":"system","voice":"Luciana (installed.luciana)"}"#.utf8)
        let event = try JSONDecoder().decode(RustConversionCoordinator.ChapterCompletionEvent.self, from: payload)
        let snapshot = event.snapshot(chapters: [event.playableChapter])
        XCTAssertEqual(snapshot.engine, "system")
        XCTAssertEqual(snapshot.voice, "Luciana (installed.luciana)")
    }

    func testProgressUsesActualSecondaryModelAndVoice() throws {
        let json = #"{"jobId":"fixture","state":"running","chaptersTotal":1,"chaptersCompleted":0,"percent":0,"engine":"edge","voice":"pt-BR-FranciscaNeural","fallbackUsed":true,"message":"Using edge"}"#
        let event = try JSONDecoder().decode(RustConversionCoordinator.ConversionProgressEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.voice, "pt-BR-FranciscaNeural")
        XCTAssertEqual(event.fallbackUsed, true)
        let manifest = #"{"manifest":{"jobId":"fixture","title":"Fixture","author":"Author","chapters":[],"usedSelections":[{"engine":"piper","model_id":"pt_BR-faber-medium"},{"engine":"edge","voice":"pt-BR-FranciscaNeural"}]}}"#
        let result = RustConversionCoordinator.Result(jobID: "fixture", manifestJSON: Data(manifest.utf8), outputDirectory: URL(fileURLWithPath: "/unused"))
        let finished = try result.snapshot()
        XCTAssertEqual(finished.engine, "edge + piper")
        XCTAssertEqual(finished.voice, "pt_BR-faber-medium + pt-BR-FranciscaNeural")
        XCTAssertEqual(event.updating(finished).voice, "pt-BR-FranciscaNeural")
    }

    func testConversionLogAppendPreservesPreviousChunkTrace() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversion-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let previousTrace = "chunk=1 chars=4096 elapsed=12.4s\n"
        try Data(previousTrace.utf8).write(to: logURL)

        try RustConversionCoordinator().appendLogLine("[Rust] conversion resumed", to: logURL)

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents, previousTrace + "[Rust] conversion resumed\n")
    }

    @MainActor
    func testStreamingIntentStartsWhenRustPublishesPlayableChapter() throws {
        let jobID = UUID().uuidString
        // The chapter file must exist and pass Rust's completed-audio check.
        let audioURL = try CompletedMP3Fixture.write(named: "stream-test")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let player = AudioPlayer()
        let pending = JobSnapshot(
            jobId: jobID, state: "running", bookTitle: "The Lord of the Rings",
            bookAuthor: "J.R.R. Tolkien", coverUrl: nil, coverMimeType: nil,
            engine: "edge", voice: nil, language: nil, progressPercent: 0,
            chaptersTotal: 1, chaptersCompleted: 0, chapterProgress: [],
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
        let chapter = JobSnapshot.Chapter(
            index: 0, name: "A Long-expected Party", status: "completed",
            downloadUrl: audioURL.path, chars: 8_000, charsProcessed: 8_000,
            progressRatio: 1, durationSeconds: nil, startedAt: nil, completedAt: nil
        )
        player.play(snapshot: pending, startingAt: 0, restoreAutoplay: false)
        player.isConverting = true
        player.resume()
        player.updateSnapshot(RustConversionCoordinator.ChapterCompletionEvent(
            jobId: jobID, bookTitle: "The Lord of the Rings", bookAuthor: "J.R.R. Tolkien",
            chapterIndex: 0, chaptersTotal: 1, chaptersCompleted: 1,
            chapterTitle: chapter.name ?? "A Long-expected Party", filename: "chapter.mp3", audioPath: audioURL,
            textChars: 8_000
        ).snapshot(chapters: [chapter]))
        XCTAssertTrue(player.isPlaying)
        player.stop()
    }

    func testRustProgressEventDecodesChapterActivityAndTerminalProgress() throws {
        let data = Data(
            #"{"jobId":"rust-job","state":"running","chapterIndex":4,"chaptersTotal":12,"chaptersCompleted":3,"percent":25.0,"engine":"edge","message":"converting chapter 5"}"#.utf8
        )

        let event = try JSONDecoder().decode(
            RustConversionCoordinator.ConversionProgressEvent.self,
            from: data
        )

        XCTAssertEqual(event.state, "running")
        XCTAssertEqual(event.chapterIndex, 4)
        XCTAssertEqual(event.chaptersCompleted, 3)
        XCTAssertEqual(event.chaptersTotal, 12)
        XCTAssertEqual(event.percent, 25)
        XCTAssertEqual(event.message, "converting chapter 5")
    }

    func testValidatedChapterEventMapsToPlayableLocalSnapshot() throws {
        let jobID = UUID().uuidString
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(jobID)-chapter.mp3")
        let payload: [String: Any] = [
            "jobId": jobID,
            "bookTitle": "The Lord of the Rings",
            "bookAuthor": "J.R.R. Tolkien",
            "chapterIndex": 7,
            "chaptersTotal": 24,
            "chaptersCompleted": 3,
            "chapterTitle": "A Long-expected Party",
            "filename": "0008-a-long-expected-party.mp3",
            "audioPath": audioURL.path,
            "textChars": 8_421,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try JSONDecoder().decode(
            RustConversionCoordinator.ChapterCompletionEvent.self,
            from: data
        )

        let chapter = event.playableChapter
        let snapshot = event.snapshot(chapters: [chapter])

        XCTAssertEqual(event.progressPercent, 12.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.jobId, jobID)
        XCTAssertEqual(snapshot.state, "running")
        XCTAssertEqual(snapshot.bookTitle, "The Lord of the Rings")
        XCTAssertNil(snapshot.engine, "A provider-neutral chapter event must not invent an Edge provider.")
        XCTAssertNil(snapshot.voice)
        XCTAssertNil(snapshot.language)
        XCTAssertEqual(snapshot.playableChapters.map(\.index), [7])
        XCTAssertEqual(snapshot.playableChapters.first?.downloadUrl, audioURL.path)
        XCTAssertEqual(snapshot.playableChapters.first?.name, "A Long-expected Party")
        XCTAssertEqual(snapshot.chaptersCompleted, 3)
        XCTAssertEqual(snapshot.chaptersTotal, 24)
    }

    func testChapterEventPreservesLiteralLocalAudioPath() throws {
        for filename in ["chapter #1?.mp3", "chapter %20 literal.mp3"] {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent(filename).path
            let payload: [String: Any] = [
                "jobId": "job", "bookTitle": "Book", "bookAuthor": "Author",
                "chapterIndex": 8, "chaptersTotal": 2, "chaptersCompleted": 1,
                "chapterTitle": "Chapter", "filename": filename,
                "audioPath": path, "textChars": 100,
            ]
            let event = try JSONDecoder().decode(RustConversionCoordinator.ChapterCompletionEvent.self,
                from: JSONSerialization.data(withJSONObject: payload))
            XCTAssertTrue(event.audioPath.isFileURL)
            XCTAssertEqual(event.audioPath.path, path)
            XCTAssertEqual(event.playableChapter.downloadUrl, path)
        }
        for path in ["chapter.mp3", "~/chapter.mp3", "https://example.invalid/chapter.mp3", "file:///tmp/chapter.mp3", "/tmp/chapter\0.mp3"] {
            let payload: [String: Any] = [
                "jobId": "job", "bookTitle": "Book", "bookAuthor": "Author",
                "chapterIndex": 8, "chaptersTotal": 2, "chaptersCompleted": 1,
                "chapterTitle": "Chapter", "filename": "chapter.mp3",
                "audioPath": path, "textChars": 100,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            XCTAssertThrowsError(try JSONDecoder().decode(RustConversionCoordinator.ChapterCompletionEvent.self, from: data))
        }
    }
}
