#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import EpubToMp3

extension AudioPlayerObservationPrivacyTests {
    @MainActor
    func testOptInExistingChapterPlaybackLatencyAndMemory() async throws {
        let input = try NativePlaybackBenchmarkInput.optIn()
        var report = try NativePlaybackBenchmarkReport(input: input)
        let identifier = "NativePlaybackBenchmark-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey, AudioPlayer.currentBookIDDefaultsKey,
                    AudioPlayer.currentChapterIndexDefaultsKey, AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey, AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let previousWidgetBook = widget?.object(forKey: "currentlyPlayingBookId")
        widget?.set("", forKey: "currentlyPlayingBookId")
        defer {
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widget?.set(previousWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: identifier)
            do { add(try report.attachment("native-existing-audio-benchmark.json")) }
            catch { XCTFail("Could not attach playback measurements: \(error)") }
        }
        for book in input.books {
            let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)))
            defer { player.stop() }
            let knownIDs = Set(LatencyObservationStore.shared.snapshot().map(\.id))
            let chapters = try await book.chapters.asyncBenchmarkChapters()
            let snapshot = JobSnapshot(jobId: UUID().uuidString, state: "finished", bookTitle: book.name, bookAuthor: nil,
                coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
                progressPercent: 100, chaptersTotal: 2, chaptersCompleted: 2, chapterProgress: chapters,
                outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
            standard.set(identifier, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            standard.set(identifier, forKey: AudioPlayer.currentBookIDDefaultsKey)
            let started = DispatchTime.now().uptimeNanoseconds
            report.points.append(.capture(book: book.name, event: "before_play", started: started))
            player.play(snapshot: snapshot, restoreAutoplay: false)
            player.resume()
            try await benchmarkWait {
                player.positionSeconds > 0 && LatencyObservationStore.shared.snapshot().contains {
                    !knownIDs.contains($0.id) && $0.records.contains { $0.transition == .audioAudible }
                }
            }
            report.points.append(.capture(book: book.name, event: "first_progressing_audio", started: started,
                                          journeys: LatencyObservationStore.shared.snapshot().filter { !knownIDs.contains($0.id) }))
            player.pause()
            for (event, expectedIndex, target) in [("seek", 0, 2.0), ("next_chapter", 1, 0.0), ("previous_chapter", 0, 0.0)] {
                let actionStart = DispatchTime.now().uptimeNanoseconds
                if event == "seek" { player.seek(to: target) }
                else if event == "next_chapter" { player.nextChapter() }
                else { player.previousChapter() }
                try await benchmarkWait {
                    guard let item = player.testHook_currentPlayerItem(), let asset = item.asset as? AVURLAsset else { return false }
                    let time = item.currentTime().seconds
                    return !player.isSeeking && asset.url == URL(fileURLWithPath: book.chapters[expectedIndex].path)
                        && item.status == .readyToPlay && time.isFinite
                        && (event != "seek" || abs(time - target) < 0.1)
                }
                XCTAssertFalse(player.isPlaying, "Paused navigation must not autoplay.")
                report.points.append(.capture(book: book.name, event: event, started: actionStart,
                                              journeys: LatencyObservationStore.shared.snapshot().filter { !knownIDs.contains($0.id) }))
            }
        }
        report.status = "completed"
    }
}
#endif
