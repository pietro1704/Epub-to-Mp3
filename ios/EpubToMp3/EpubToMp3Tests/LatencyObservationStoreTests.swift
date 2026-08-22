import XCTest
@testable import EpubToMp3

final class LatencyObservationStoreTests: XCTestCase {
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

    func testDiagnosticExportWritesOnlySnapshotData() throws {
        let store = LatencyObservationStore(clock: { 42 })
        _ = store.beginBookOpen(documentKind: .selectableTextPDF)

        let url = try store.writeDiagnosticExport()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("selectable_text_pdf"))
        XCTAssertFalse(json.contains("bookTitle"))
        XCTAssertFalse(json.contains("author"))
        XCTAssertFalse(json.contains("audio"))
    }

    func testProgressivePlaybackJourneyPreservesCorrelationAndReadinessBoundaries() throws {
        var now: UInt64 = 1_000
        let store = LatencyObservationStore(clock: { now })
        let correlationID = UUID()

        let journeyID = store.beginProgressivePlayback(correlationID: correlationID)
        now = 1_030
        XCTAssertTrue(store.record(.audioQueued, for: journeyID))
        now = 1_080
        XCTAssertTrue(store.record(.audioAudible, for: journeyID))

        let journey = try XCTUnwrap(store.snapshot().first)
        XCTAssertEqual(journey.kind, .progressivePlayback)
        XCTAssertEqual(journey.correlationID, correlationID)
        XCTAssertEqual(
            journey.records.map(\.transition),
            [.playRequested, .audioQueued, .audioAudible]
        )
        XCTAssertEqual(journey.records.map(\.elapsedNanoseconds), [0, 30, 80])
    }
}
