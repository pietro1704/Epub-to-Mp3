#if canImport(AVFoundation) && canImport(MediaPlayer)
import XCTest
import AVFoundation
@testable import EpubToMp3

/// Unit tests for the play-tap divergence routing added to
/// `AudioPlayer`: chapter-index translation, decision matrix,
/// sentence-level seek lookup, ratio fallback, and the pending-seek
/// queue that survives the AVPlayer asset-prepare gap.
final class AudioPlayerDivergenceTests: XCTestCase {

    @MainActor
    func makePlayer() -> AudioPlayer { AudioPlayer() }

    func snapshotWithChapters(_ count: Int, jobID: String = "test-job") -> JobSnapshot {
        let chapters: [JobSnapshot.Chapter] = (0..<count).map { idx in
            JobSnapshot.Chapter(
                index: idx,
                name: "Chapter \(idx + 1)",
                status: "completed",
                downloadUrl: "/api/jobs/test/chapters/\(idx)/mp3",
                chars: 1000,
                charsProcessed: 1000,
                progressRatio: 1.0,
                durationSeconds: 60,
                startedAt: nil,
                completedAt: nil
            )
        }
        return JobSnapshot(
            jobId: jobID,
            state: "done",
            bookTitle: "Test Book",
            bookAuthor: "Author",
            coverUrl: nil,
            coverMimeType: nil,
            engine: nil,
            voice: nil,
            language: "en",
            progressPercent: 100,
            chaptersTotal: count,
            chaptersCompleted: count,
            chapterProgress: chapters,
            outputs: nil,
            logUrl: nil,
            error: nil,
            lastActivityAt: nil
        )
    }

    // MARK: playTapDecision












    // MARK: Segment queue chapter reconciliation


    // MARK: JobSnapshot index translation


    // MARK: setSentenceTiming cache




    // MARK: Pending reader-page navigation

    func pendingReaderSnapshot(jobID: String) throws -> JobSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "jobId": jobID, "state": "running", "bookTitle": "Pending reader fixture",
            "chaptersTotal": 1, "chaptersCompleted": 0,
        ])
        return try JSONDecoder().decode(JobSnapshot.self, from: data)
    }

    @MainActor
    func readerAudioFixture(valid: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("reader seek \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chapter.wav")
        if valid {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0 }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } else {
            try Data("Invalid audio fixture".utf8).write(to: url)
        }
        return url
    }

    func playableReaderSnapshot(jobID: String, url: URL) throws -> JobSnapshot {
        let data = try JSONSerialization.data(withJSONObject: [
            "jobId": jobID, "state": "running", "bookTitle": "Pending reader fixture",
            "chaptersTotal": 1, "chaptersCompleted": 1,
            "chapterProgress": [[
                "index": 0, "name": "Chapter 1", "status": "completed",
                "downloadUrl": url.absoluteString, "chars": 1000,
                "charsProcessed": 1000, "progressRatio": 1.0, "durationSeconds": 10,
            ]],
        ])
        return try JSONDecoder().decode(JobSnapshot.self, from: data)
    }

    @MainActor
    func waitForReaderState(_ description: String, _ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }








}
#endif
