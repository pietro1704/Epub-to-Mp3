#if canImport(AVFoundation) && canImport(MediaPlayer)
import Combine
import Foundation
import MediaPlayer
import XCTest
@testable import EpubToMp3

final class PlaybackCompositionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        private static let standardKeys = [AudioPlayer.currentBookIDDefaultsKey,
            AudioPlayer.currentChapterIndexDefaultsKey, ReaderSessionState.currentlyReadingBookIDKey,
            AudioPlayer.readerCurrentChapterIndexDefaultsKey, AudioPlayer.readerCurrentPageRatioDefaultsKey,
            AudioPlayer.readerCurrentSentenceIdDefaultsKey]
        private static let widgetKeys = ["currentlyPlayingBookId", "widget.nowPlayingChapterName",
            "widget.nowPlayingAuthor", "widget.nowPlayingProgress", "widget.nowPlayingIsPlaying",
            "widget.nowPlayingPositionSeconds", "widget.nowPlayingDurationSeconds",
            "widget.nowPlayingChapterRemainingSeconds", "widget.nowPlayingBookRemainingSeconds",
            "widget.nowPlayingTotalChapters"]
        private let suite = "PlaybackComposition-\(UUID().uuidString)"
        private let defaults: UserDefaults
        private let standardValues: [Any?]
        private let widget: UserDefaults?
        private let widgetValues: [Any?]
        private let nowPlaying: [String: Any]?
        let resumeStore: ResumeStore

        init() throws {
            let privateDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults = privateDefaults
            resumeStore = ResumeStore(storage: UserDefaultsResumeStorage(defaults: privateDefaults))
            standardValues = Self.standardKeys.map { UserDefaults.standard.object(forKey: $0) }
            let group = UserDefaults(suiteName: WidgetDataSync.appGroupID)
            widget = group
            widgetValues = Self.widgetKeys.map { group?.object(forKey: $0) }
            nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo
            UserDefaults.standard.set(suite, forKey: AudioPlayer.currentBookIDDefaultsKey)
            UserDefaults.standard.set(suite, forKey: ReaderSessionState.currentlyReadingBookIDKey)
            // Empty identity prevents publication from targeting a real widget book.
            group?.set("", forKey: "currentlyPlayingBookId")
        }

        func restore(afterStopping player: AudioPlayer?) {
            player?.stop()
            for (key, value) in zip(Self.standardKeys, standardValues) {
                UserDefaults.standard.set(value, forKey: key)
            }
            for (key, value) in zip(Self.widgetKeys, widgetValues) { widget?.set(value, forKey: key) }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func snapshot(id: String) throws -> JobSnapshot {
        try JSONDecoder().decode(JobSnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "jobId": id, "state": "running", "chaptersTotal": 1, "chaptersCompleted": 0,
            "chapterProgress": [["index": 0, "name": "First", "status": "pending"]]
        ]))
    }

    @MainActor
    func testComposedServicesReleaseAuthorityAndFinishChapterSubscribers() async throws {
        let fixture = try Fixture()
        var player: AudioPlayer? = AudioPlayer(resumeStore: fixture.resumeStore)
        defer { fixture.restore(afterStopping: player) }
        weak var released = player
        let waiting = try snapshot(id: UUID().uuidString)
        player?.play(snapshot: waiting, restoreAutoplay: false)
        player?.updateReaderChapterTitle("First", for: 0)
        player?.pause()
        let accepted = await player?.enqueueSegmentAsync(data: Data(), chapterIndex: 0, segmentIndex: 0)
        XCTAssertEqual(accepted, false)
        var chapters = try XCTUnwrap(player?.currentChapter).makeAsyncIterator()
        _ = await chapters.next()
        player?.stop()
        player = nil
        guard released == nil else { return XCTFail("The composition graph must keep authority weak") }
        let finished = expectation(description: "Chapter subscribers finish with the composition graph")
        let completion = Task { @MainActor in
            let ended = await chapters.next()
            XCTAssertNil(ended, "Service lifetime cannot outlive the released coordinator")
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        completion.cancel()
        await completion.value
    }

    @MainActor
    func testComposedAuthorityPreservesSynchronousPublicationAndSnapshotCacheOrder() throws {
        let fixture = try Fixture()
        let player = AudioPlayer(resumeStore: fixture.resumeStore)
        defer { fixture.restore(afterStopping: player) }
        var previous: [(Bool, Bool, PlaybackRate, Bool, String?)] = []
        let observer = player.objectWillChange.sink {
            previous.append((player.isPlaying, player.isSeeking, player.rate,
                             player.isUsingSpeechFallback, player.snapshot?.jobId))
        }
        defer { observer.cancel() }
        player.playbackPlayingChanged(true)
        XCTAssertEqual(previous.count, 1)
        XCTAssertFalse(previous[0].0)
        player.playbackSeekingChanged(true)
        XCTAssertEqual(previous.count, 2)
        XCTAssertFalse(previous[1].1)
        player.playbackRateChanged(.x125)
        XCTAssertEqual(previous.count, 3)
        XCTAssertEqual(previous[2].2, .x100)
        player.playbackSpeechChanged(true)
        XCTAssertEqual(previous.count, 4)
        XCTAssertFalse(previous[3].3)
        player.playbackSpeechChanged(true)
        XCTAssertEqual(previous.count, 5, "Equal assignments retain the original Published contract")
        let book = try snapshot(id: "composed-book")
        player.playbackSnapshotChanged(book)
        XCTAssertEqual(previous.count, 6)
        XCTAssertNil(previous[5].4)
        XCTAssertEqual(player.snapshot?.jobId, "composed-book")
        XCTAssertEqual(player.cachedBookChapterProgress?.chapters.count, 1)
    }

    @MainActor
    func testRootStopInvalidatesGenerationAndReleasesReadinessWithoutGrantingPlayback() throws {
        let fixture = try Fixture()
        let player = AudioPlayer(resumeStore: fixture.resumeStore)
        defer { fixture.restore(afterStopping: player) }
        let book = try snapshot(id: "composed-stop")
        XCTAssertTrue(player.beginRemoteStreaming(snapshot: book, backendBaseURL: URL(string: "https://example.invalid")!))
        player.startFromReaderPage(0, sentenceOffsetRatio: 0.5)
        let oldGeneration = player.remotePlaybackGeneration
        XCTAssertTrue(player.isSeeking)
        XCTAssertNotNil(player.pendingNavigation)
        player.stop()
        XCTAssertNotEqual(player.remotePlaybackGeneration, oldGeneration)
        XCTAssertNil(player.snapshot)
        XCTAssertNil(player.pendingNavigation)
        XCTAssertNil(player.cachedBookChapterProgress)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.isSeeking)
        XCTAssertFalse(player.hasLoadedAudioQueue)
        XCTAssertFalse(player.hasPausedPlaybackToResume)
    }
}
#endif
