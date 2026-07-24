//
//  SessionRowModelTests.swift
//  EpubToMp3Tests
//
//  Pure row-mapping coverage for the UIKit sessions list
//  (JobsListCollectionView), now the default renderer on iOS/iPadOS.
//

import XCTest
@testable import EpubToMp3

final class SessionRowModelTests: XCTestCase {

    private func session(
        outcome: String? = nil,
        engine: String? = nil,
        chapters: Int? = nil
    ) -> SessionRecord {
        SessionRecord(
            timestamp: "2026-05-08T10:23:45",
            bookTitle: "Foundation",
            engine: engine,
            chaptersConverted: chapters,
            durationSeconds: 1800,
            outcome: outcome,
            mode: "cli"
        )
    }

    func testMakePreservesIdentityAndTitle() {
        let row = SessionRowModel.make(from: session())
        XCTAssertEqual(row.id, "2026-05-08T10:23:45|Foundation")
        XCTAssertEqual(row.title, "Foundation")
    }

    func testOutcomeStateMapping() {
        XCTAssertEqual(SessionRowModel.make(from: session(outcome: "success")).outcomeState, .success)
        XCTAssertEqual(SessionRowModel.make(from: session(outcome: "PARTIAL")).outcomeState, .partial)
        XCTAssertEqual(SessionRowModel.make(from: session(outcome: "failed")).outcomeState, .failed)
        XCTAssertEqual(SessionRowModel.make(from: session(outcome: nil)).outcomeState, .unknown)
        XCTAssertEqual(SessionRowModel.make(from: session(outcome: "weird")).outcomeState, .unknown)
    }

    func testOutcomeTextCapitalized() {
        XCTAssertEqual(SessionRowModel.make(from: session(outcome: "success")).outcomeText, "Success")
        XCTAssertNil(SessionRowModel.make(from: session(outcome: nil)).outcomeText)
    }

    func testEngineTextOmittedWhenEmpty() {
        XCTAssertNil(SessionRowModel.make(from: session(engine: "")).engineText)
        XCTAssertEqual(SessionRowModel.make(from: session(engine: "edge")).engineText, "edge")
    }

    func testTimestampTruncatedTo19Chars() {
        let row = SessionRowModel.make(from: session())
        XCTAssertEqual(row.timestampText, "2026-05-08T10:23:45")
        XCTAssertEqual(row.timestampText.count, 19)
    }

    func testDetailTextJoinsNonNilFieldsWithSeparator() {
        let row = SessionRowModel.make(from: session(engine: "edge", chapters: 24))
        XCTAssertTrue(row.detailText.contains("edge"))
        XCTAssertTrue(row.detailText.contains("·"))
        XCTAssertTrue(row.detailText.hasSuffix("2026-05-08T10:23:45"))
    }

    func testDetailTextSkipsMissingFieldsWithoutDanglingSeparators() {
        let row = SessionRowModel.make(from: session(engine: nil, chapters: nil))
        XCTAssertFalse(row.detailText.hasPrefix("·"))
        XCTAssertEqual(row.detailText, "2026-05-08T10:23:45")
    }

    func testRowsPreservesOrder() {
        let sessions = [session(engine: "edge"), session(engine: "piper")]
        let rows = SessionRowModel.rows(from: sessions)
        XCTAssertEqual(rows.map(\.engineText), ["edge", "piper"])
    }
}
