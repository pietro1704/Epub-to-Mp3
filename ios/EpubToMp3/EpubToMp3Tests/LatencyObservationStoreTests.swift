import XCTest
import AVFoundation
@testable import EpubToMp3

final class LatencyObservationStoreTests: XCTestCase {
    func testStreamRequestCannotMoveBetweenJourneysOrPublications() throws {
        let store = LatencyObservationStore(clock: { 100 })
        let first = store.beginSeek()
        let second = store.beginSeek()
        let receipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
            journeyID: first, requestID: UUID(), publicationID: "0"))
        XCTAssertFalse(store.attachStreamRequest(receipt, for: second))
        XCTAssertTrue(store.attachStreamRequest(receipt, for: first))
        XCTAssertFalse(store.attachStreamRequest(receipt, for: first))
        let wrong = try XCTUnwrap(LatencyObservation.StreamPublication(publicationID: "1", producer: producer()))
        XCTAssertFalse(store.attachStreamPublication(wrong, for: first))
        let correct = try XCTUnwrap(LatencyObservation.StreamPublication(publicationID: "0", producer: producer()))
        XCTAssertTrue(store.attachStreamPublication(correct, for: first))
        XCTAssertTrue(store.attachStreamPublication(wrong, for: second))
        let wrongReceipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
            journeyID: second, requestID: UUID(), publicationID: "0"))
        XCTAssertFalse(store.attachStreamRequest(wrongReceipt, for: second))
        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self, from: store.exportData())
        XCTAssertEqual(exported.first?.streamRequest, receipt)
        XCTAssertEqual(exported.first?.records.map(\.elapsedNanoseconds), [0])
        XCTAssertNil(exported.last?.streamRequest)
    }

    func testTerminalEvictedAndBookOpenJourneysRejectHTTPReceipts() throws {
        let store = LatencyObservationStore(capacity: 3)
        let evicted = store.beginSeek()
        let cancelled = store.beginSeek()
        store.cancel(cancelled)
        let finished = store.beginSeek()
        store.finish(finished)
        let open = store.beginBookOpen(documentKind: .epub)
        for id in [evicted, cancelled, finished, open, UUID()] {
            let receipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
                journeyID: id, requestID: UUID(), publicationID: "0"))
            XCTAssertFalse(store.attachStreamRequest(receipt, for: id))
        }
        XCTAssertTrue(store.snapshot().allSatisfy { $0.streamRequest == nil })
    }

    private func producer() throws -> LatencyObservation.ProducerObservation {
        try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
            #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":9000,"artifactPublishedElapsedNanoseconds":9500}"#.utf8))
    }

    func testStreamPublicationIsFirstOnlyAndDoesNotChangeClientClock() throws {
        var now: UInt64 = 100
        let store = LatencyObservationStore(clock: { now })
        let first = try XCTUnwrap(LatencyObservation.StreamPublication(
            publicationID: "fe0d56d1366149db89d4324a355fb35a", producer: producer()))
        let retry = try XCTUnwrap(LatencyObservation.StreamPublication(
            publicationID: UUID().uuidString, producer: producer()))
        let id = store.beginProgressivePlayback()
        now = 110
        XCTAssertTrue(store.record(.audioQueued, for: id))
        now = 120
        XCTAssertTrue(store.attachStreamPublication(first, for: id))
        XCTAssertFalse(store.attachStreamPublication(retry, for: id))
        XCTAssertTrue(store.record(.audioAudible, for: id))
        store.finish(id)
        XCTAssertFalse(store.attachStreamPublication(retry, for: id))
        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self, from: store.exportData())
        XCTAssertEqual(exported.first?.streamPublication, first)
        XCTAssertEqual(exported.first?.records.map(\.elapsedNanoseconds), [0, 10, 20])
        XCTAssertEqual(exported.first?.streamPublication?.producer.artifactPublishedElapsedNanoseconds, 9500)
    }

    func testCancelledEvictedAndBookOpenJourneysRejectStreamPublication() throws {
        let store = LatencyObservationStore(capacity: 2)
        let publication = try XCTUnwrap(LatencyObservation.StreamPublication(
            publicationID: "0", producer: producer()))
        let evicted = store.beginSeek()
        let cancelled = store.beginSeek()
        XCTAssertTrue(store.cancel(cancelled))
        let open = store.beginBookOpen(documentKind: .epub)
        for id in [evicted, cancelled, open, UUID()] {
            XCTAssertFalse(store.attachStreamPublication(publication, for: id))
        }
        XCTAssertTrue(store.snapshot().allSatisfy { $0.streamPublication == nil })
        let live = store.beginSeek()
        XCTAssertTrue(store.attachStreamPublication(publication, for: live))
    }

    func testPublicationIdentifiersCannotExportContentOrPaths() throws {
        let observation = try producer()
        for id in ["", "Private_Book_Title", "/private/audio.mp3", "-1", "１２３",
                   String(repeating: "1", count: 21), "{" + UUID().uuidString + "}"] {
            XCTAssertNil(LatencyObservation.StreamPublication(publicationID: id, producer: observation))
        }
        for id in ["0", String(repeating: "1", count: 20), UUID().uuidString,
                   "fe0d56d1366149db89d4324a355fb35a"] {
            let publication = try XCTUnwrap(LatencyObservation.StreamPublication(
                publicationID: id, producer: observation))
            let data = try JSONEncoder().encode(publication)
            XCTAssertEqual(try JSONDecoder().decode(LatencyObservation.StreamPublication.self, from: data), publication)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(json.keys), Set(["publicationId", "producer"]))
        }
    }

    func testCapacityEvictsOldestJourneyAndRejectsItsLateCallbacks() throws {
        let store = LatencyObservationStore(clock: { 100 }, capacity: 2)
        let evicted = store.beginSeek()
        let retained = store.beginBookOpen(documentKind: .epub)
        let newest = store.beginProgressivePlayback()

        XCTAssertEqual(store.snapshot().map(\.id), [retained, newest])
        XCTAssertFalse(store.record(.seekTargetReached, for: evicted))
        XCTAssertFalse(store.cancel(evicted))
        store.classifyCache(.cold, for: evicted)
        store.finish(evicted)
        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self, from: store.exportData())
        XCTAssertEqual(exported.map(\.id), [retained, newest],
                       "Late callbacks must not resurrect evicted diagnostics or evict newer journeys.")
    }

    func testRepeatedReadinessKeepsFirstTimingAndBoundsJourneyRecords() throws {
        var now: UInt64 = 100
        let store = LatencyObservationStore(clock: { now }, capacity: 1)
        let id = store.beginBookOpen(documentKind: .normalizedScannedPDF)
        now = 120
        XCTAssertTrue(store.record(.readableContent, for: id))
        now = 130
        XCTAssertTrue(store.record(.controlsUsable, for: id))
        now = 140
        XCTAssertTrue(store.record(.firstPDFPage, for: id))
        now = 200
        for _ in 0..<1_000 {
            _ = store.record(.readableContent, for: id)
            _ = store.record(.controlsUsable, for: id)
            _ = store.record(.firstPDFPage, for: id)
        }
        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self, from: store.exportData())
        let journey = try XCTUnwrap(exported.first)
        XCTAssertEqual(journey.records.count, 4,
                       "Repeated layout/readiness callbacks must not grow local diagnostics without bound.")
        XCTAssertEqual(Array(journey.records.prefix(4)).map(\.elapsedNanoseconds), [0, 20, 30, 40])
        XCTAssertFalse(store.record(.readableContent, for: id))
        XCTAssertTrue(store.cancel(id))
        XCTAssertEqual(store.snapshot().first?.records.count, 5)
    }

    func testBookOpenJourneyExportsOrderedRedactedRecords() throws {
        var now: UInt64 = 1_000
        let store = LatencyObservationStore(clock: { now })

        let journeyID = store.beginBookOpen(documentKind: .epub)
        store.classifyCache(.inMemoryWarm, for: journeyID)

        now = 1_080
        XCTAssertTrue(store.record(.readableContent, for: journeyID))
        now = 1_120
        XCTAssertTrue(store.record(.controlsUsable, for: journeyID))

        let journey = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(journey.id, journeyID)
        XCTAssertEqual(journey.context.documentKind, .epub)
        XCTAssertEqual(journey.context.cacheClass, .inMemoryWarm)
        XCTAssertEqual(
            journey.records.map(\.transition),
            [.openRequested, .readableContent, .controlsUsable]
        )
        XCTAssertEqual(journey.records.map(\.elapsedNanoseconds), [0, 80, 120])

        let export = try store.exportData()
        let json = try XCTUnwrap(String(data: export, encoding: .utf8))
        XCTAssertTrue(json.contains("in_memory_warm"))
        XCTAssertFalse(json.contains("Foundation"))
        XCTAssertFalse(json.contains("Asimov"))
        XCTAssertFalse(json.contains("/private/"))
    }

    func testCancelledJourneyRejectsLaterReadyStates() throws {
        var now: UInt64 = 500
        let store = LatencyObservationStore(clock: { now })

        let journeyID = store.beginBookOpen(documentKind: .normalizedScannedPDF)
        now = 550
        XCTAssertTrue(store.cancel(journeyID))
        now = 600
        XCTAssertFalse(store.record(.firstPDFPage, for: journeyID))

        let journey = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(journey.records.map(\.transition), [.openRequested, .cancelled])
        XCTAssertEqual(journey.records.map(\.elapsedNanoseconds), [0, 50])
    }

    func testFinishedJourneyRejectsLateCancellation() throws {
        let store = LatencyObservationStore(clock: { 100 })
        let journeyID = store.beginBookOpen(documentKind: .epub)

        store.finish(journeyID)

        XCTAssertFalse(store.cancel(journeyID))
        XCTAssertEqual(
            try XCTUnwrap(store.snapshot().first).records.map(\.transition),
            [.openRequested]
        )
    }

    func testPreparedPDFJourneyReclassifiesNormalizedDocument() throws {
        var now: UInt64 = 10
        let store = LatencyObservationStore(clock: { now })

        let journeyID = store.beginBookOpen(documentKind: .selectableTextPDF)
        store.classifyCache(.preparedDisk, for: journeyID)
        store.classifyDocument(.normalizedScannedPDF, for: journeyID)
        now = 35
        XCTAssertTrue(store.record(.readableContent, for: journeyID))
        XCTAssertTrue(store.record(.firstPDFPage, for: journeyID))

        let journey = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(journey.context.documentKind, .normalizedScannedPDF)
        XCTAssertEqual(journey.context.cacheClass, .preparedDisk)
        XCTAssertEqual(
            journey.records.map(\.transition),
            [.openRequested, .readableContent, .firstPDFPage]
        )
        XCTAssertEqual(journey.records.map(\.elapsedNanoseconds), [0, 25, 25])
    }

    func testDiagnosticExportWritesOnlySnapshotData() async throws {
        let store = LatencyObservationStore(clock: { 42 })
        _ = store.beginBookOpen(documentKind: .selectableTextPDF)

        let url = try await store.writeDiagnosticExport()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("selectable_text_pdf"))
        XCTAssertFalse(json.contains("bookTitle"))
        XCTAssertFalse(json.contains("author"))
        XCTAssertFalse(json.contains("audio"))
    }

    func testProgressivePlaybackKeepsQueuedAndAudibleBoundariesDistinct() throws {
        var now: UInt64 = 100
        let store = LatencyObservationStore(clock: { now })

        let journeyID = store.beginProgressivePlayback()
        now = 130
        XCTAssertTrue(store.record(.audioQueued, for: journeyID))
        now = 170
        XCTAssertTrue(store.record(.audioAudible, for: journeyID))
        store.finish(journeyID)

        let journey = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(journey.kind, .progressivePlayback)
        XCTAssertEqual(
            journey.records.map(\.transition),
            [.playRequested, .audioQueued, .audioAudible]
        )
        XCTAssertEqual(journey.records.map(\.elapsedNanoseconds), [0, 30, 70])
        XCTAssertEqual(store.latestElapsedNanoseconds(for: journeyID), 70)
    }

    func testProgressivePlaybackRejectsAudibleBeforeQueueReadiness() throws {
        let store = LatencyObservationStore(clock: { 100 })
        let journeyID = store.beginProgressivePlayback()

        XCTAssertFalse(store.record(.audioAudible, for: journeyID))
        XCTAssertTrue(store.record(.audioQueued, for: journeyID))
        XCTAssertTrue(store.record(.audioAudible, for: journeyID))

        XCTAssertEqual(
            try XCTUnwrap(store.snapshot().first).records.map(\.transition),
            [.playRequested, .audioQueued, .audioAudible]
        )
    }

    func testSeekJourneyDoesNotCompleteWhenCancelledBeforeTarget() throws {
        var now: UInt64 = 10
        let store = LatencyObservationStore(clock: { now })

        let journeyID = store.beginSeek()
        now = 25
        XCTAssertTrue(store.cancel(journeyID))
        now = 40
        XCTAssertFalse(store.record(.seekTargetReached, for: journeyID))

        let journey = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(journey.kind, .seek)
        XCTAssertEqual(journey.records.map(\.transition), [.seekRequested, .cancelled])
    }

    func testAudiblePlaybackRequiresRenderingRatherThanQueueReadiness() {
        XCTAssertFalse(AudioPlayer.hasAudibleOutput(timeControlStatus: .paused, renderedSeconds: 3))
        XCTAssertFalse(AudioPlayer.hasAudibleOutput(timeControlStatus: .playing, renderedSeconds: 0))
        XCTAssertTrue(AudioPlayer.hasAudibleOutput(timeControlStatus: .playing, renderedSeconds: 0.01))
    }
}
