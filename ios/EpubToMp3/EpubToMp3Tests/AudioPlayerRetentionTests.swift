#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
@testable import EpubToMp3

final class AudioPlayerRetentionTests: XCTestCase {
    @MainActor
    private func withFixture(
        _ body: (AudioPlayer, LocalAudioArtifactStore, URL, String, JobSnapshot, [Data]) async throws -> Void
    ) async throws {
        let bookID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Retention-\(bookID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let artifactRoot = root.appendingPathComponent("artifacts", isDirectory: true)
        let store = LocalAudioArtifactStore(root: artifactRoot)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Retention-\(bookID)"))
        let standard = UserDefaults.standard
        let keys = [ReaderSessionState.currentlyReadingBookIDKey,
                    AudioPlayer.currentBookIDDefaultsKey, AudioPlayer.currentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentChapterIndexDefaultsKey,
                    AudioPlayer.readerCurrentPageRatioDefaultsKey,
                    AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        let saved = keys.map { standard.object(forKey: $0) }
        let widget = UserDefaults(suiteName: WidgetDataSync.appGroupID)
        let savedWidgetBook = widget?.object(forKey: "currentlyPlayingBookId")
        widget?.set("", forKey: "currentlyPlayingBookId")
        standard.set(bookID, forKey: ReaderSessionState.currentlyReadingBookIDKey)
        standard.set(bookID, forKey: AudioPlayer.currentBookIDDefaultsKey)
        let player = AudioPlayer(resumeStore: ResumeStore(storage: UserDefaultsResumeStorage(defaults: defaults)),
                                 artifactStore: store)
        defer {
            player.stop()
            for (key, value) in zip(keys, saved) { standard.set(value, forKey: key) }
            widget?.set(savedWidgetBook, forKey: "currentlyPlayingBookId")
            defaults.removePersistentDomain(forName: "Retention-\(bookID)")
            try? FileManager.default.removeItem(at: root)
        }
        try await store.prepare(bookID: bookID, bookTitle: "Retention fixture", author: nil,
                                chapters: [.init(index: 0, title: "First"), .init(index: 1, title: "Second")])
        for index in 0...1 { try await store.markGenerating(bookID: bookID, chapterIndex: index) }
        var audio: [Data] = []
        for index in 0...1 {
            let url = root.appendingPathComponent("fixture-\(index).wav")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let frames: AVAudioFrameCount = index == 0 ? 24_000 : 48_000
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<Int(frames) {
                samples[frame] = Float(sin(Double(frame) * 2 * .pi * Double(440 + index * 100) / 8_000)) * 0.01
            }
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            audio.append(try Data(contentsOf: url))
        }
        let snapshot = JobSnapshot(jobId: "embedded-\(bookID)", state: "running",
            bookTitle: "Retention fixture", bookAuthor: nil, coverUrl: nil, coverMimeType: nil,
            engine: nil, voice: nil, language: "en", progressPercent: 0, chaptersTotal: 2, chaptersCompleted: 0,
            chapterProgress: (0...1).map { index in
                .init(index: index, name: index == 0 ? "First" : "Second", status: "processing",
                    downloadUrl: nil, chars: 100, charsProcessed: 0, progressRatio: 0,
                    durationSeconds: index == 0 ? 3 : 6, startedAt: nil, completedAt: nil)
            }, outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil)
        XCTAssertTrue(snapshot.playableChapters.isEmpty)
        XCTAssertTrue(player.beginRemoteStreaming(snapshot: snapshot,
            backendBaseURL: URL(string: "https://retention.invalid")!))
        try await body(player, store, artifactRoot, bookID, snapshot, audio)
    }

    @MainActor
    func testEveryAudibleStreamedChapterGetsDurableRetentionWithoutAnotherPlayRequest() async throws {
        try await withFixture { player, store, artifactRoot, bookID, _, audio in
            for index in 0...1 {
                player.enqueueSegment(data: audio[index], chapterIndex: index, segmentIndex: 0)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.positionSeconds, 0)
            for index in 0...1 {
                let artifact = try await store.artifact(bookID: bookID, chapterIndex: index)
                XCTAssertNotEqual(artifact?.playbackRetentionRequested, true)
            }
            player.resume()
            for _ in 0..<100 {
                if player.currentChapterIndex == 0 && player.positionSeconds > 0.25 { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(player.currentChapterIndex, 0)
            XCTAssertGreaterThan(player.positionSeconds, 0.25, "The first chapter must really advance")
            let unplayedSecond = try await store.artifact(bookID: bookID, chapterIndex: 1)
            XCTAssertNotEqual(unplayedSecond?.playbackRetentionRequested, true)
            // Let AVQueuePlayer advance naturally; never issue a second Play.
            for _ in 0..<240 {
                if player.currentChapterIndex == 1 && player.positionSeconds > 0.25 { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual(player.currentChapterIndex, 1)
            XCTAssertGreaterThan(player.positionSeconds, 0.25, "The second chapter must really advance")
            player.pause()
            for _ in 0..<40 {
                let chapters = try await store.manifest(bookID: bookID)?.chapters ?? []
                if chapters.allSatisfy({ $0.playbackRetentionRequested == true }) { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            // Check retention only after proving both audible chapters, so a
            // missing first marker cannot hide the second-chapter regression.
            for index in 0...1 {
                let artifact = try await store.artifact(bookID: bookID, chapterIndex: index)
                XCTAssertEqual(artifact?.playbackRetentionRequested, true, "Audible chapter \(index) needs durable intent")
                let canonical = try await store.canonicalURL(bookID: bookID, chapterIndex: index)
                try audio[index].write(to: canonical)
                try await store.markAvailable(bookID: bookID, chapterIndex: index)
            }
            let restored = LocalAudioArtifactStore(root: artifactRoot)
            let downloaded = try await restored.downloadedIndices(bookID: bookID)
            XCTAssertEqual(downloaded, Set([0, 1]))
            for index in 0...1 {
                let canonical = try await restored.canonicalURL(bookID: bookID, chapterIndex: index)
                XCTAssertEqual(try Data(contentsOf: canonical), audio[index])
                let artifact = try await restored.artifact(bookID: bookID, chapterIndex: index)
                XCTAssertEqual(artifact?.retention, .downloaded)
            }
        }
    }

    @MainActor
    func testArrivalFollowedByImmediatePauseDoesNotRetainUnaudibleChapter() async throws {
        try await withFixture { player, store, artifactRoot, bookID, _, audio in
            player.resume()
            // No suspension between enqueue and pause: the periodic MainActor
            // callback cannot report rendered output before the pause intent.
            player.enqueueSegment(data: audio[0], chapterIndex: 0, segmentIndex: 0)
            player.pause()
            XCTAssertFalse(player.isPlaying)
            XCTAssertEqual(player.positionSeconds, 0)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(player.positionSeconds, 0)
            let artifact = try await store.artifact(bookID: bookID, chapterIndex: 0)
            XCTAssertNotEqual(artifact?.playbackRetentionRequested, true)
            let restored = LocalAudioArtifactStore(root: artifactRoot)
            let persisted = try await restored.artifact(bookID: bookID, chapterIndex: 0)
            XCTAssertNotEqual(persisted?.playbackRetentionRequested, true)
            XCTAssertEqual(persisted?.retention, .temporary)
        }
    }

    @MainActor
    func testFullFileRetentionFollowsAudibleQueueWhenSnapshotSortOrderChanges() async throws {
        try await withFixture { player, store, artifactRoot, bookID, snapshot, audio in
            var urls: [URL] = []
            for index in 0...1 {
                let url = try await store.canonicalURL(bookID: bookID, chapterIndex: index)
                try audio[index].write(to: url)
                try await store.markAvailable(bookID: bookID, chapterIndex: index)
                urls.append(url)
            }
            func chapter(_ index: Int, completed: Bool) -> JobSnapshot.Chapter {
                .init(index: index, name: index == 0 ? "First" : "Second",
                    status: completed ? "completed" : "pending",
                    downloadUrl: completed ? urls[index].absoluteString : nil,
                    chars: 100, charsProcessed: completed ? 100 : 0,
                    progressRatio: completed ? 1 : 0, durationSeconds: index == 0 ? 3 : 6,
                    startedAt: nil, completedAt: nil)
            }
            var initial = snapshot
            initial.chapterProgress = [chapter(0, completed: false), chapter(1, completed: true)]
            player.play(snapshot: initial, startingAt: 0, restoreAutoplay: false)
            player.resume()
            for _ in 0..<100 {
                let retained = try await store.artifact(bookID: bookID, chapterIndex: 1)
                let renderedSeconds = player.testHook_currentPlayerItem()?.currentTime().seconds ?? 0
                if renderedSeconds > 0.25 && retained?.retention == .downloaded { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertTrue(player.isPlaying)
            let originalItem = try XCTUnwrap(player.testHook_currentPlayerItem())
            XCTAssertEqual((originalItem.asset as? AVURLAsset)?.url, urls[1])
            XCTAssertGreaterThan(originalItem.currentTime().seconds, 0.25)
            let initialRetained = try await store.downloadedIndices(bookID: bookID)
            XCTAssertEqual(initialRetained, Set([1]))

            var updated = snapshot
            updated.chapterProgress = [chapter(0, completed: true), chapter(1, completed: true)]
            XCTAssertEqual(updated.playableChapters.map(\.index), [0, 1])
            player.updateSnapshot(updated)
            let beforeTick = originalItem.currentTime().seconds
            try await Task.sleep(nanoseconds: 750_000_000)
            XCTAssertTrue(player.testHook_currentPlayerItem() === originalItem,
                          "A newly published earlier chapter must not interrupt the current audio")
            XCTAssertTrue(player.isPlaying)
            XCTAssertGreaterThan(originalItem.currentTime().seconds, beforeTick)
            let notYetHeard = try await store.artifact(bookID: bookID, chapterIndex: 0)
            XCTAssertNotEqual(notYetHeard?.playbackRetentionRequested, true,
                              "Sorted snapshot position zero is not the audible chapter")
            XCTAssertEqual(notYetHeard?.retention, .temporary)

            // The appended chapter becomes audible only after a real queue advance.
            player.nextChapter()
            for _ in 0..<100 {
                let currentItem = player.testHook_currentPlayerItem()
                let currentURL = (currentItem?.asset as? AVURLAsset)?.url
                let renderedSeconds = currentItem?.currentTime().seconds ?? 0
                let retained = try await store.artifact(bookID: bookID, chapterIndex: 0)
                if currentURL == urls[0] && renderedSeconds > 0.25 && retained?.retention == .downloaded { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertTrue(player.isPlaying)
            XCTAssertEqual((player.testHook_currentPlayerItem()?.asset as? AVURLAsset)?.url, urls[0])
            let finalItem = try XCTUnwrap(player.testHook_currentPlayerItem())
            let finalTime = finalItem.currentTime().seconds
            XCTAssertGreaterThan(finalTime, 0.25)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(player.testHook_currentPlayerItem() === finalItem)
            XCTAssertGreaterThan(finalItem.currentTime().seconds, finalTime)
            let restored = LocalAudioArtifactStore(root: artifactRoot)
            let retainedAfterHearingBoth = try await restored.downloadedIndices(bookID: bookID)
            XCTAssertEqual(retainedAfterHearingBoth, Set([0, 1]))
        }
    }
}
#endif
