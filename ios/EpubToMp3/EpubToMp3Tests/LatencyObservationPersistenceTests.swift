import Foundation
import XCTest
@testable import EpubToMp3

final class LatencyObservationPersistenceTests: XCTestCase {
    func testHTTPReceiptSurvivesExportAndRelaunchWithoutReopeningConsentOrJourney() async throws {
        let url = try location()
        let original = LatencyObservationStore(clock: { 100 }, persistence: .init(fileURL: url))
        let id = original.beginSeek()
        let receipt = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
            journeyID: id, requestID: UUID(), publicationID: "0"))
        XCTAssertTrue(original.attachStreamRequest(receipt, for: id))
        original.cancel(id)
        await original.flushPersistence()
        let restored = LatencyObservationStore(clock: { 1 }, persistence: .init(fileURL: url))
        let exportedURL = try await restored.writeDiagnosticExport(to: url.appendingPathExtension("export"))
        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self,
                                                from: Data(contentsOf: exportedURL))
        XCTAssertEqual(exported, original.snapshot())
        XCTAssertEqual(exported.first?.streamRequest, receipt)
        XCTAssertEqual(exported.first?.records.map(\.transition), [.seekRequested, .cancelled])
        XCTAssertFalse(restored.attachStreamRequest(receipt, for: id))
        XCTAssertFalse(StreamingDiagnosticsSession().isActive)
    }

    func testArchiveRejectsWrongJourneyAndBookOpenHTTPReceipts() async throws {
        for mode in ["wrongJourney", "bookOpen", "wrongPublication"] {
            let url = try location()
            let source = LatencyObservationStore()
            let id = mode == "bookOpen" ? source.beginBookOpen(documentKind: .epub) : source.beginSeek()
            var invalid = try XCTUnwrap(source.snapshot().first)
            invalid.streamRequest = try XCTUnwrap(LatencyObservation.StreamRequestReceipt(
                journeyID: mode == "wrongJourney" ? UUID() : id, requestID: UUID(), publicationID: "0"))
            if mode == "wrongPublication" {
                let producer = try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
                    #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":0,"artifactPublishedElapsedNanoseconds":1}"#.utf8))
                invalid.streamPublication = try XCTUnwrap(.init(publicationID: "1", producer: producer))
            }
            let persistence = LatencyObservationPersistence(fileURL: url)
            persistence.schedule([invalid], revision: 1)
            await persistence.flush()
            let restored = LatencyObservationStore(persistence: .init(fileURL: url))
            await restored.flushPersistence()
            XCTAssertTrue(restored.snapshot().isEmpty, mode)
        }
    }

    func testBookOpenArchiveCannotCarryStreamPublication() async throws {
        let url = try location()
        let producer = try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
            #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":0,"artifactPublishedElapsedNanoseconds":1}"#.utf8))
        let source = LatencyObservationStore()
        _ = source.beginBookOpen(documentKind: .epub)
        var invalid = try XCTUnwrap(source.snapshot().first)
        invalid.streamPublication = try XCTUnwrap(LatencyObservation.StreamPublication(
            publicationID: "0", producer: producer))
        let persistence = LatencyObservationPersistence(fileURL: url)
        persistence.schedule([invalid], revision: 1)
        await persistence.flush()
        let restored = LatencyObservationStore(persistence: .init(fileURL: url))
        await restored.flushPersistence()
        XCTAssertTrue(restored.snapshot().isEmpty)
        let live = restored.beginSeek()
        await restored.flushPersistence()
        XCTAssertEqual(restored.snapshot().map(\.id), [live])
    }

    func testStreamPublicationSurvivesRelaunchWithoutResumingProducerOrClientClock() async throws {
        let url = try location()
        let producer = try JSONDecoder().decode(LatencyObservation.ProducerObservation.self, from: Data(
            #"{"version":1,"attemptId":"FE0D56D1-3661-49DB-89D4-324A355FB35A","segmentReadyElapsedNanoseconds":9000,"artifactPublishedElapsedNanoseconds":9500}"#.utf8))
        let publication = try XCTUnwrap(LatencyObservation.StreamPublication(
            publicationID: UUID().uuidString, producer: producer))
        var now: UInt64 = 100
        let original = LatencyObservationStore(clock: { now }, persistence: .init(fileURL: url))
        let id = original.beginSeek()
        now = 120
        XCTAssertTrue(original.attachStreamPublication(publication, for: id))
        XCTAssertTrue(original.record(.seekTargetReached, for: id))
        original.finish(id)
        await original.flushPersistence()
        let restored = LatencyObservationStore(clock: { 1 }, persistence: .init(fileURL: url))
        let export = try await restored.writeDiagnosticExport(to: url.appendingPathExtension("export"))
        let journeys = try JSONDecoder().decode([LatencyObservation.Journey].self, from: Data(contentsOf: export))
        XCTAssertEqual(journeys, original.snapshot())
        XCTAssertEqual(journeys.first?.streamPublication, publication)
        XCTAssertEqual(journeys.first?.records.map(\.elapsedNanoseconds), [0, 20])
        XCTAssertFalse(restored.attachStreamPublication(publication, for: id))
    }

    func testImmediateExportAfterReopeningIncludesStoredHistory() async throws {
        let url = try location()
        let original = LatencyObservationStore(persistence: .init(fileURL: url))
        let id = original.beginBookOpen(documentKind: .epub)
        XCTAssertTrue(original.record(.readableContent, for: id))
        await original.flushPersistence()
        let restored = LatencyObservationStore(persistence: .init(fileURL: url))
        // Exercise the Settings export boundary without flushing or waiting
        // for hydration separately after constructing the reopened store.
        let destination = url.deletingLastPathComponent().appendingPathComponent("export.json")
        let exportedURL = try await restored.writeDiagnosticExport(to: destination)
        XCTAssertEqual(exportedURL, destination)
        let exported = try JSONDecoder().decode([LatencyObservation.Journey].self,
                                               from: Data(contentsOf: exportedURL))
        XCTAssertEqual(exported, original.snapshot())
    }

    private func location() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatencyPersistence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("Diagnostics/archive.json")
    }

    func testRestorePreservesElapsedHistoryAndRejectsOldClockMutations() async throws {
        let url = try location()
        var now: UInt64 = 1_000
        let original = LatencyObservationStore(clock: { now }, persistence: .init(fileURL: url))
        let oldID = original.beginSeek()
        now = 1_150
        XCTAssertTrue(original.record(.seekTargetReached, for: oldID))
        original.finish(oldID)
        await original.flushPersistence()
        let previous = original.snapshot()

        let restored = LatencyObservationStore(clock: { 5 }, persistence: .init(fileURL: url))
        // Start before hydration finishes: live records must survive the merge.
        let liveID = restored.beginBookOpen(documentKind: .epub)
        XCTAssertTrue(restored.record(.readableContent, for: liveID))
        await restored.flushPersistence()
        XCTAssertEqual(restored.snapshot().first, previous.first)
        XCTAssertEqual(restored.snapshot().map(\.id), [oldID, liveID])
        XCTAssertFalse(restored.record(.seekTargetReached, for: oldID))
        XCTAssertFalse(restored.cancel(oldID))
        XCTAssertEqual(restored.snapshot().last?.records.map(\.elapsedNanoseconds), [0, 0])
        let reloaded = LatencyObservationStore(persistence: .init(fileURL: url))
        await reloaded.flushPersistence()
        XCTAssertEqual(reloaded.snapshot(), restored.snapshot())
    }

    func testUnfinishedPriorJourneyRemainsHistoricalWithoutInventedCancellation() async throws {
        let url = try location()
        let original = LatencyObservationStore(clock: { 900 }, persistence: .init(fileURL: url))
        let id = original.beginProgressivePlayback()
        XCTAssertTrue(original.record(.audioQueued, for: id))
        await original.flushPersistence()
        let restored = LatencyObservationStore(clock: { 1 }, persistence: .init(fileURL: url))
        await restored.flushPersistence()
        XCTAssertFalse(restored.record(.audioAudible, for: id))
        XCTAssertFalse(restored.cancel(id))
        XCTAssertEqual(restored.snapshot().first?.records.map(\.transition), [.playRequested, .audioQueued])
    }

    func testRetentionKeepsNewestTwoHundredAndExportStaysAnArray() async throws {
        let url = try location()
        let store = LatencyObservationStore(capacity: 1_000, persistence: .init(fileURL: url))
        let ids = (0..<240).map { _ in store.beginBookOpen(documentKind: .epub) }
        await store.flushPersistence()
        let restored = LatencyObservationStore(persistence: .init(fileURL: url))
        await restored.flushPersistence()
        XCTAssertEqual(restored.snapshot().map(\.id), Array(ids.suffix(200)))
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, LatencyObservationPersistence.maximumBytes)
        let exported = try JSONSerialization.jsonObject(with: restored.exportData())
        XCTAssertTrue(exported is [[String: Any]])
    }

    func testSmallCapacityMergesHistoryBeforeLiveObservations() async throws {
        let url = try location()
        let original = LatencyObservationStore(persistence: .init(fileURL: url))
        _ = original.beginSeek()
        let lastOld = original.beginSeek()
        await original.flushPersistence()
        let restored = LatencyObservationStore(capacity: 2, persistence: .init(fileURL: url))
        let newest = restored.beginSeek()
        await restored.flushPersistence()
        XCTAssertEqual(restored.snapshot().map(\.id), [lastOld, newest])
    }

    func testCorruptOversizedAndUnknownVersionArchivesDoNotBlockNewEvents() async throws {
        let url = try location()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bytes in [Data("not-json".utf8), Data(repeating: 0x20, count: LatencyObservationPersistence.maximumBytes + 1),
                      Data("{\"version\":99,\"journeys\":[]}".utf8)] {
            try bytes.write(to: url)
            let store = LatencyObservationStore(persistence: .init(fileURL: url))
            let id = store.beginSeek()
            await store.flushPersistence()
            XCTAssertEqual(store.snapshot().map(\.id), [id])
            let restored = LatencyObservationStore(persistence: .init(fileURL: url))
            await restored.flushPersistence()
            XCTAssertEqual(restored.snapshot().map(\.id), [id])
        }
    }

    func testDirectoryAndArtifactAreExcludedFromBackup() async throws {
        let url = try location()
        let store = LatencyObservationStore(persistence: .init(fileURL: url))
        _ = store.beginSeek()
        await store.flushPersistence()
        for location in [url, url.deletingLastPathComponent()] {
            XCTAssertEqual(try location.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
    }

    func testOlderSubmissionCannotReplaceNewestSnapshot() async throws {
        let url = try location()
        let fixture = LatencyObservationStore(clock: { 1 })
        _ = fixture.beginSeek()
        let old = fixture.snapshot()
        _ = fixture.beginBookOpen(documentKind: .epub)
        let latest = fixture.snapshot()
        let persistence = LatencyObservationPersistence(fileURL: url)
        persistence.schedule(latest, revision: 2)
        persistence.schedule(old, revision: 1)
        await persistence.flush()
        let restored = LatencyObservationStore(persistence: .init(fileURL: url))
        await restored.flushPersistence()
        XCTAssertEqual(restored.snapshot(), latest)
    }

    func testUnwritableDestinationKeepsLiveDiagnosticsUsable() async throws {
        let url = try location()
        try Data("occupied".utf8).write(to: url.deletingLastPathComponent())
        let store = LatencyObservationStore(persistence: .init(fileURL: url))
        let id = store.beginSeek()
        XCTAssertTrue(store.record(.seekTargetReached, for: id))
        await store.flushPersistence()
        XCTAssertEqual(store.snapshot().first?.id, id)
        XCTAssertNoThrow(try store.exportData())
    }
}
