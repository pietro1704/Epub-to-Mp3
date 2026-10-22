#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
@testable import EpubToMp3

final class PlaybackChapterExecutionTests: XCTestCase {
    private func chapter(_ index: Int, url: URL? = nil) -> JobSnapshot.Chapter {
        .init(index: index, name: "Chapter \(index)", status: url == nil ? "pending" : "completed",
              downloadUrl: url?.absoluteString, chars: nil, charsProcessed: nil,
              progressRatio: nil, durationSeconds: nil, startedAt: nil, completedAt: nil)
    }
    private func snapshot(id: String, chapters: [JobSnapshot.Chapter], state: String = "running") -> JobSnapshot {
        .init(jobId: id, state: state, bookTitle: "Fixture", bookAuthor: nil,
              coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: "en",
              progressPercent: nil, chaptersTotal: chapters.count, chaptersCompleted: nil,
              chapterProgress: chapters, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
    }
    private func audioFile(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    @MainActor
    func testRootChapterUpdateKeepsCurrentItemAndNeverGrantsAutoplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try PlaybackPublicationFixture()
        let player = AudioPlayer(resumeStore: fixture.resumeStore)
        defer {
            fixture.restore(afterStopping: player)
            try? FileManager.default.removeItem(at: directory)
        }
        let currentURL = try audioFile(in: directory)
        let earlierURL = try audioFile(in: directory)
        let id = UUID().uuidString
        player.play(snapshot: snapshot(id: id, chapters: [chapter(7, url: currentURL)]), restoreAutoplay: false)
        let current = try XCTUnwrap(player.testHook_currentPlayerItem())
        XCTAssertTrue(player.hasLoadedAudioQueue)
        XCTAssertFalse(player.isPlaying)
        player.updateSnapshot(snapshot(id: id, chapters: [chapter(3, url: earlierURL), chapter(7, url: currentURL)]))
        XCTAssertTrue(player.testHook_currentPlayerItem() === current)
        XCTAssertEqual(player.testHook_playbackChapterCount(), 2)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testMissingChapterFilesRemainWaitingAndTerminalLoadSurfacesFailure() throws {
        let fixture = try PlaybackPublicationFixture()
        let player = AudioPlayer(resumeStore: fixture.resumeStore)
        defer { fixture.restore(afterStopping: player) }
        let id = UUID().uuidString
        player.play(snapshot: snapshot(id: id, chapters: [chapter(7)]), restoreAutoplay: false)
        XCTAssertFalse(player.hasLoadedAudioQueue)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.lastError)
        player.play(snapshot: snapshot(id: id, chapters: [chapter(7)], state: "finished"), restoreAutoplay: false)
        XCTAssertFalse(player.hasLoadedAudioQueue)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.lastError, .noPlayableChapters)
    }

    @MainActor
    func testFullFileHandoffPreservesWaitingPageRequestAndPauseIntent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = try PlaybackPublicationFixture()
        let player = AudioPlayer(resumeStore: fixture.resumeStore)
        defer {
            fixture.restore(afterStopping: player)
            try? FileManager.default.removeItem(at: directory)
        }
        let id = UUID().uuidString
        let waiting = snapshot(id: id, chapters: [chapter(7)])
        XCTAssertTrue(player.beginRemoteStreaming(snapshot: waiting, backendBaseURL: URL(string: "https://example.invalid")!))
        player.startFromReaderPage(7, sentenceOffsetRatio: 0.5)
        let request = try XCTUnwrap(player.pendingNavigation)
        player.pause()
        let file = try audioFile(in: directory)
        player.finishStreaming(snapshot: snapshot(id: id, chapters: [chapter(7, url: file)], state: "finished"))
        XCTAssertEqual(player.pendingNavigation?.requestID, request.requestID)
        XCTAssertEqual(player.snapshot?.jobId, id)
        XCTAssertFalse(player.isPlaying)
        for _ in 0..<80 where player.isSeeking { try await Task.sleep(nanoseconds: 25_000_000) }
        XCTAssertFalse(player.isSeeking)
        XCTAssertNil(player.pendingNavigation)
        XCTAssertFalse(player.isPlaying, "File availability cannot replace the user's Pause intent")
        XCTAssertEqual(player.positionSeconds, 0.5, accuracy: 0.05)
    }
}
#endif
