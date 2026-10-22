#if canImport(AVFoundation) && canImport(MediaPlayer)
import Foundation
import AVFoundation
import XCTest
@testable import EpubToMp3

final class PlaybackOwnershipTests: XCTestCase {
    @MainActor
    func testPersistenceAcknowledgesOnlyDurableOriginalIdentity() async throws {
        let persistence = PlaybackSegmentPersistence(writer: SegmentFileWriter())
        defer { persistence.removeDirectory() }
        let identity = SegmentBacklog.Identity(chapterIndex: 7, segmentIndex: 3)
        let bytes = Data([1, 2, 3, 4])
        var accepted: URL?
        var failures = 0
        let first = await persistence.enqueue(data: bytes, identity: identity,
            validate: { accepted == nil ? .current : .duplicate }, prepare: { true },
            failed: { failures += 1 }, accept: { accepted = $0 })
        XCTAssertTrue(first)
        let original = try XCTUnwrap(accepted)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let retry = await persistence.enqueue(data: Data([9]), identity: identity,
            validate: { .duplicate }, prepare: { XCTFail("Duplicate must skip preparation"); return true },
            failed: { failures += 1 }, accept: { _ in XCTFail("Duplicate must not replace the original") })
        XCTAssertTrue(retry)
        XCTAssertEqual(accepted, original)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(failures, 0)
    }

    @MainActor
    func testPersistenceFailureDoesNotAcknowledgeOrRetainPartialFile() async throws {
        enum Failure: Error { case write }
        let persistence = PlaybackSegmentPersistence(writer: SegmentFileWriter(write: { data, url in
            try data.write(to: url)
            throw Failure.write
        }))
        defer { persistence.removeDirectory() }
        var failures = 0
        let result = await persistence.enqueue(data: Data([1]), identity: .init(chapterIndex: 0, segmentIndex: 0),
            validate: { .current }, prepare: { true }, failed: { failures += 1 },
            accept: { _ in XCTFail("Failed writes must not reach the queue") })
        XCTAssertFalse(result)
        XCTAssertEqual(failures, 1)
        let directory = try XCTUnwrap(persistence.directory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @MainActor
    func testCancelledOrReplacedPersistenceNeverAcceptsAudio() async throws {
        for cancel in [false, true] {
            let persistence = PlaybackSegmentPersistence(writer: SegmentFileWriter())
            defer { persistence.removeDirectory() }
            var valid = true
            var release: CheckedContinuation<Bool, Never>?
            let task = Task { @MainActor in
                await persistence.enqueue(data: Data([5]), identity: .init(chapterIndex: 2, segmentIndex: 0),
                    validate: { valid ? .current : .invalid },
                    prepare: { await withCheckedContinuation { release = $0 } },
                    failed: { XCTFail("Cancellation/replacement is not a write error") },
                    accept: { _ in XCTFail("Stale audio must not reach the queue") })
            }
            defer { task.cancel() }
            for _ in 0..<200 where release == nil { await Task.yield() }
            let continuation = try XCTUnwrap(release)
            if cancel { task.cancel() } else { valid = false }
            continuation.resume(returning: true)
            let result = await task.value
            XCTAssertFalse(result)
            XCTAssertNil(persistence.directory)
        }
    }

    @MainActor
    func testBufferedProducerDoesNotMoveAudibleSegmentCursorOrDuration() {
        let session = PlaybackSegmentSession()
        let first = SegmentBacklog.Identity(chapterIndex: 2, segmentIndex: 0)
        session.register(URL(fileURLWithPath: "/first.mp3"), identity: first, sentenceID: "first",
                         publication: nil, receipt: nil)
        XCTAssertNil(session.activeIdentity)
        XCTAssertTrue(session.activate(first))
        session.estimate(30, chapter: 2)
        session.setBase(5)
        let later = SegmentBacklog.Identity(chapterIndex: 8, segmentIndex: 0)
        session.register(URL(fileURLWithPath: "/later.mp3"), identity: later, sentenceID: "later",
                         publication: nil, receipt: nil)
        session.estimate(900, chapter: 8)
        XCTAssertEqual(session.activeIdentity, first)
        XCTAssertEqual(session.chapterIndex, 2)
        XCTAssertEqual(session.chapterDuration, 30)
        XCTAssertEqual(session.cumulativeBase, 5)
        XCTAssertFalse(session.activate(first))
        XCTAssertTrue(session.activate(later))
        XCTAssertEqual(session.cumulativeBase, 0)
        XCTAssertEqual(session.chapterDuration, 0)
        session.resetMetadata()
        XCTAssertTrue(session.files.isEmpty)
        XCTAssertNil(session.activeIdentity)
    }

    @MainActor
    func testDeferredCapacityCancellationAndTeardownCompleteWaiters() async {
        let session = PlaybackSegmentSession()
        session.deferSegment(url: URL(fileURLWithPath: "/queued.mp3"), chapterIndex: 0, segmentIndex: 0, sentenceId: nil)
        let cancelled = Task { @MainActor in await session.waitForCapacity(maximumCount: 1) }
        for _ in 0..<200 where session.capacityWaiterCount == 0 { await Task.yield() }
        XCTAssertEqual(session.capacityWaiterCount, 1)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        XCTAssertEqual(session.capacityWaiterCount, 0)
        let stopped = Task { @MainActor in await session.waitForCapacity(maximumCount: 1) }
        for _ in 0..<200 where session.capacityWaiterCount == 0 { await Task.yield() }
        XCTAssertEqual(session.capacityWaiterCount, 1)
        if session.capacityWaiterCount == 0 { stopped.cancel() }
        session.cancelWaiters()
        let stoppedResult = await stopped.value
        XCTAssertFalse(stoppedResult)
        XCTAssertEqual(session.deferredCount, 1)
        session.clearDeferred()
        let available = await session.waitForCapacity(maximumCount: 1)
        XCTAssertTrue(available)
    }

    @MainActor
    func testPendingSeekPublishesRequestIdentityAndCancellation() {
        var navigation: AudioPlayer.PendingNavigation?
        let pending = PendingPlaybackSeek { navigation = $0 }
        let id = UUID()
        pending.chapter = .init(id: id, jobID: "original", chapterIndex: 9, autoplay: true)
        XCTAssertEqual(navigation?.requestID, id)
        pending.chapter?.autoplay = false
        XCTAssertEqual(navigation?.requestID, id)
        XCTAssertEqual(pending.chapter?.autoplay, false)
        pending.activeID = UUID()
        pending.autoplay = true
        pending.cancel()
        XCTAssertNil(navigation)
        XCTAssertNil(pending.chapter)
        XCTAssertNil(pending.activeID)
        XCTAssertNil(pending.autoplay)
    }

    @MainActor
    func testJourneyQueuedMilestoneIsOnceAndAudibleCompletionRetainsIdentity() throws {
        let store = LatencyObservationStore()
        let recorder = PlaybackJourneyRecorder(store: store)
        recorder.beginPlaybackJourneyIfNeeded()
        let id = try XCTUnwrap(recorder.playbackID)
        recorder.beginPlaybackJourneyIfNeeded()
        recorder.recordQueuedAudioIfNeeded()
        recorder.recordQueuedAudioIfNeeded()
        recorder.recordAudibleAudioIfNeeded(audible: false, attach: { _ in XCTFail("Buffered is not audible") })
        XCTAssertEqual(recorder.playbackID, id)
        var attached: UUID?
        recorder.recordAudibleAudioIfNeeded(audible: true, attach: { attached = $0 })
        XCTAssertEqual(attached, id)
        XCTAssertNil(recorder.playbackID)
        let journey = try XCTUnwrap(store.snapshot().first { $0.id == id })
        XCTAssertEqual(journey.records.filter { $0.transition == .audioQueued }.count, 1)
        XCTAssertEqual(journey.records.filter { $0.transition == .audioAudible }.count, 1)
    }

    @MainActor
    func testQueueMembershipUsesItemIdentityAndTeardownClearsOwnership() {
        let session = PlaybackQueueSession()
        let url = URL(fileURLWithPath: "/same-segment.mp3")
        let owned = AVPlayerItem(url: url)
        let unrelated = AVPlayerItem(url: url)
        session.mount(AVQueuePlayer())
        session.register(ObjectIdentifier(owned))
        XCTAssertTrue(session.owns(ObjectIdentifier(owned)))
        XCTAssertFalse(session.removeOwnership(ObjectIdentifier(unrelated)))
        XCTAssertTrue(session.removeOwnership(ObjectIdentifier(owned)))
        XCTAssertFalse(session.removeOwnership(ObjectIdentifier(owned)))
        session.register(ObjectIdentifier(owned))
        session.teardown()
        XCTAssertNil(session.player)
        XCTAssertFalse(session.owns(ObjectIdentifier(owned)))
    }

    @MainActor
    func testBroadcastRegistersSynchronouslyAndFinishesAllSubscribersOnRelease() async {
        var owner: PlaybackBroadcast? = PlaybackBroadcast()
        var first = owner!.positions(initial: 2).makeAsyncIterator()
        var second = owner!.positions(initial: 8).makeAsyncIterator()
        let firstInitial = await first.next()
        let secondInitial = await second.next()
        XCTAssertEqual(firstInitial, 2)
        XCTAssertEqual(secondInitial, 8)
        owner?.publishPosition(13)
        let firstPosition = await first.next()
        let secondPosition = await second.next()
        XCTAssertEqual(firstPosition, 13)
        XCTAssertEqual(secondPosition, 13)
        owner = nil
        let firstEnd = await first.next()
        let secondEnd = await second.next()
        XCTAssertNil(firstEnd)
        XCTAssertNil(secondEnd)
    }

    @MainActor
    func testSeekHandoffPreservesIdentityWithoutCancellation() throws {
        let store = LatencyObservationStore()
        let recorder = PlaybackJourneyRecorder(store: store)
        recorder.beginSeekJourney()
        let first = try XCTUnwrap(recorder.seekID)
        let preserved = recorder.suspendSeek()
        recorder.cancelSeek()
        recorder.restoreSeek(preserved)
        XCTAssertEqual(recorder.seekID, first)
        recorder.completeSeekJourney { XCTAssertEqual($0, first) }
        XCTAssertNil(recorder.seekID)
        let journey = try XCTUnwrap(store.snapshot().first { $0.id == first })
        XCTAssertFalse(journey.records.contains { $0.transition == .cancelled })
        XCTAssertTrue(journey.records.contains { $0.transition == .seekTargetReached })
        recorder.beginSeekJourney()
        let cancelled = try XCTUnwrap(recorder.seekID)
        recorder.cancelSeek()
        XCTAssertTrue(try XCTUnwrap(store.snapshot().first { $0.id == cancelled }).records.contains { $0.transition == .cancelled })
    }
    @MainActor
    func testSegmentPreparationEscalatesOnlyConsecutiveEmptyDataAndPreservesDuplicate() {
        let session = PlaybackSegmentSession()
        let identity = SegmentBacklog.Identity(chapterIndex: 4, segmentIndex: 2)
        for _ in 1..<SegmentBacklog.emptyStreakErrorThreshold {
            guard case .ignored = session.prepare(data: Data(), identity: identity, hasPlayer: false) else {
                return XCTFail("Warmup empties must not immediately surface an error")
            }
        }
        guard case .emptyFailure = session.prepare(data: Data(), identity: identity, hasPlayer: false) else {
            return XCTFail("A persistent empty streak must surface a failure")
        }
        guard case .accepted = session.prepare(data: Data([1]), identity: identity, hasPlayer: false) else {
            return XCTFail("Usable audio must reset the empty streak")
        }
        guard case .ignored = session.prepare(data: Data(), identity: identity, hasPlayer: false) else {
            return XCTFail("A later single empty is a new warmup streak")
        }
        let original = URL(fileURLWithPath: "/original.mp3")
        session.register(original, identity: identity, sentenceID: "original", publication: nil, receipt: nil)
        guard case .ignored = session.prepare(data: Data([9]), identity: identity, hasPlayer: true) else {
            return XCTFail("A retried producer must not overwrite a retained AVFoundation asset")
        }
        XCTAssertEqual(session.files[identity], original)
        XCTAssertEqual(session.sentenceIDs[identity], "original")
        XCTAssertNil(session.activeIdentity)
    }

}
#endif
