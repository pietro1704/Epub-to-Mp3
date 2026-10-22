#if canImport(AVFoundation) && canImport(MediaPlayer)
import AVFoundation
import Foundation
import XCTest
@testable import EpubToMp3

final class PlaybackStreamAdmissionTests: XCTestCase {
    @MainActor
    func testDurableAdmissionPublishesReadinessOnceAndPreservesDuplicateFile() async throws {
        let segments = PlaybackSegmentSession()
        let persistence = PlaybackSegmentPersistence(writer: SegmentFileWriter())
        let queue = PlaybackQueueSession()
        let readiness = PlaybackConversionReadiness()
        defer { queue.teardown(); persistence.removeDirectory() }
        let generation = UUID()
        var preparation = 0
        var created = 0
        var ready = 0
        let owner = PlaybackStreamAdmission(segments: segments, persistence: persistence, queue: queue,
            readiness: readiness, journeys: PlaybackJourneyRecorder(), actions: .init(
                prepare: { preparation += 1 }, isCurrent: { $0 == generation }, accepting: {},
                created: { player, identity in
                    created += 1
                    XCTAssertFalse(readiness.firstSegmentReady, "Readiness follows queue creation")
                    XCTAssertTrue(queue.player === player)
                    XCTAssertEqual(identity.chapterIndex, 7)
                }, ready: { ready += 1 }, failed: { _ in XCTFail("Usable data must persist") }))
        let identity = SegmentBacklog.Identity(chapterIndex: 7, segmentIndex: 0)
        let accepted = await owner.enqueueAsync(data: Data([1, 2]), identity: identity, generation: generation,
            sentenceID: "original", publication: nil, receipt: nil, maximumDeferredSegments: 1)
        XCTAssertTrue(accepted)
        let original = try XCTUnwrap(segments.files[identity])
        let duplicate = await owner.enqueueAsync(data: Data([9]), identity: identity, generation: generation,
            sentenceID: "replacement", publication: nil, receipt: nil, maximumDeferredSegments: 1)
        XCTAssertTrue(duplicate)
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2]))
        XCTAssertEqual(segments.sentenceIDs[identity], "original")
        XCTAssertEqual(preparation, 1)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(ready, 1)
        XCTAssertTrue(readiness.firstSegmentReady)
        XCTAssertTrue(readiness.firstChapterReady)
        XCTAssertEqual(queue.player?.rate, 0, "Admission alone never grants autoplay")
    }

    @MainActor
    func testCapacitySuspensionRejectsReplacementAndCancellationBeforePersistence() async throws {
        for cancel in [false, true] {
            let segments = PlaybackSegmentSession()
            let persistence = PlaybackSegmentPersistence(writer: SegmentFileWriter())
            let queue = PlaybackQueueSession()
            defer { queue.teardown(); persistence.removeDirectory() }
            let generation = UUID()
            var current = generation
            segments.deferSegment(url: URL(fileURLWithPath: "/buffered.mp3"), chapterIndex: 0,
                                  segmentIndex: 0, sentenceId: nil)
            let owner = PlaybackStreamAdmission(segments: segments, persistence: persistence, queue: queue,
                readiness: PlaybackConversionReadiness(), journeys: PlaybackJourneyRecorder(), actions: .init(
                    prepare: {}, isCurrent: { $0 == current }, accepting: { XCTFail("Stale admission") },
                    created: { _, _ in XCTFail("Stale queue") }, ready: { XCTFail("Stale readiness") },
                    failed: { _ in XCTFail("Cancellation is not a write failure") }))
            let pending = Task { @MainActor in
                await owner.enqueueAsync(data: Data([1]), identity: .init(chapterIndex: 3, segmentIndex: 0),
                    generation: generation, sentenceID: nil, publication: nil, receipt: nil, maximumDeferredSegments: 1)
            }
            for _ in 0..<200 where segments.capacityWaiterCount == 0 { await Task.yield() }
            XCTAssertEqual(segments.capacityWaiterCount, 1)
            if cancel { pending.cancel() } else { current = UUID() }
            segments.clearDeferred()
            segments.resumeWaiters()
            let accepted = await pending.value
            XCTAssertFalse(accepted)
            XCTAssertNil(persistence.directory)
            XCTAssertTrue(segments.files.isEmpty)
            XCTAssertNil(queue.player)
        }
    }

    @MainActor
    func testWriteFailureNeverRaisesReadyOrCreatesAQueue() async {
        enum Failure: Error { case write }
        let persistence = PlaybackSegmentPersistence(writer: SegmentFileWriter(write: { _, _ in throw Failure.write }))
        let queue = PlaybackQueueSession()
        let readiness = PlaybackConversionReadiness()
        defer { queue.teardown(); persistence.removeDirectory() }
        var errors: [PlaybackFailure] = []
        let owner = PlaybackStreamAdmission(segments: PlaybackSegmentSession(), persistence: persistence, queue: queue,
            readiness: readiness, journeys: PlaybackJourneyRecorder(), actions: .init(
                prepare: {}, isCurrent: { _ in true }, accepting: { XCTFail("Failed write cannot admit") },
                created: { _, _ in XCTFail("Failed write cannot create") }, ready: { XCTFail("Failed write cannot publish") },
                failed: { errors.append($0) }))
        let accepted = await owner.enqueueAsync(data: Data([1]), identity: .init(chapterIndex: 1, segmentIndex: 0),
            generation: UUID(), sentenceID: nil, publication: nil, receipt: nil, maximumDeferredSegments: 1)
        XCTAssertFalse(accepted)
        XCTAssertEqual(errors, [.segmentWriteFailed])
        XCTAssertFalse(readiness.firstSegmentReady)
        XCTAssertNil(queue.player)
    }
}
#endif
