#if canImport(AVFoundation) && canImport(MediaPlayer)
import Foundation
import XCTest
@testable import EpubToMp3

final class PlaybackSeekExecutionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let clock = PlaybackClock()
        lazy var queue = PlaybackQueueSession(clock: clock)
        var snapshot: JobSnapshot?
        var navigation: PendingPlaybackSeek.PendingNavigation?
        var events: [String] = []
        lazy var execution: PlaybackSeekExecution = PlaybackSeekExecution(queue: queue, segments: PlaybackSegmentSession(),
            chapters: PlaybackChapterSession(), reader: ReaderPlaybackSeek(), navigation: ChapterNavigationDecision(),
            journeys: PlaybackJourneyRecorder(store: LatencyObservationStore()), clock: clock,
            broadcast: PlaybackBroadcast(), navigationChanged: { [weak self] in self?.navigation = $0 },
            actions: .init(snapshot: { [weak self] in self?.snapshot }, segmentMode: { false }, isPlaying: { false },
                seeking: { [weak self] in self?.events.append("seeking:\($0)") },
                pauseTransport: { [weak self] in self?.events.append("pause") },
                cancelAutoplay: { [weak self] in self?.events.append("cancel-autoplay") },
                play: { [weak self] _, _ in self?.events.append("play") },
                resume: { [weak self] in self?.events.append("resume") },
                publish: { [weak self] in self?.events.append("publish") },
                chapterChanged: { [weak self] in self?.events.append("chapter") },
                attachPublication: { _ in }, resolveURL: { _, _, _ in nil }, chapterURLs: { nil }))
    }

    @MainActor
    func testReaderWaitingRequestRetainsIdentityAndCancelsWithoutAutoplay() throws {
        let fixture = Fixture()
        fixture.snapshot = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"waiting-book","state":"running","chaptersTotal":8,"chaptersCompleted":0}"#.utf8))
        fixture.execution.startFromReaderPage(7, sentenceOffsetRatio: 0.5)
        let request = try XCTUnwrap(fixture.execution.pending.chapter)
        XCTAssertEqual(request.jobID, "waiting-book")
        XCTAssertEqual(request.chapterIndex, 7)
        XCTAssertEqual(request.readerPageRatio, 0.5)
        XCTAssertEqual(fixture.navigation?.requestID, request.id)
        XCTAssertEqual(fixture.events, ["cancel-autoplay", "seeking:false", "seeking:true", "pause", "publish"])
        fixture.execution.pending.chapter?.autoplay = false
        XCTAssertEqual(fixture.navigation?.requestID, request.id, "Pause updates intent without replacing the request")
        fixture.execution.cancel()
        XCTAssertNil(fixture.execution.pending.chapter)
        XCTAssertNil(fixture.navigation)
        XCTAssertEqual(fixture.events.last, "seeking:false")
        XCTAssertFalse(fixture.events.contains("resume"))
    }

    @MainActor
    func testProportionalRequestCannotApplyToAnotherBook() throws {
        let fixture = Fixture()
        fixture.snapshot = try JSONDecoder().decode(JobSnapshot.self,
            from: Data(#"{"jobId":"current-book","state":"running","chaptersTotal":1,"chaptersCompleted":0}"#.utf8))
        fixture.clock.update(positionSeconds: 2, durationSeconds: 12)
        fixture.execution.pending.proportional = .init(ratio: 0.5, jobID: "obsolete-book", forChapterIndex: 0)
        fixture.execution.applyPendingProportionalSeek()
        XCTAssertEqual(fixture.clock.positionSeconds, 2)
        XCTAssertNil(fixture.execution.pending.proportional)
        XCTAssertTrue(fixture.events.isEmpty)
        fixture.execution.pending.proportional = .init(ratio: 0.25, jobID: "current-book", forChapterIndex: 0)
        fixture.execution.applyPendingProportionalSeek()
        XCTAssertEqual(fixture.clock.positionSeconds, 3)
        XCTAssertNil(fixture.execution.pending.proportional)
        XCTAssertEqual(fixture.events, ["seeking:false", "publish"])
    }

    @MainActor
    func testNonfiniteSeekWithoutQueuePublishesZeroAndCannotResume() {
        let fixture = Fixture()
        fixture.clock.update(positionSeconds: 9)
        fixture.execution.seek(to: .infinity)
        XCTAssertEqual(fixture.clock.positionSeconds, 0)
        XCTAssertEqual(fixture.events, ["seeking:false", "publish"])
        XCTAssertNil(fixture.execution.pending.activeID)
        XCTAssertFalse(fixture.events.contains("resume"))
    }
}
#endif
