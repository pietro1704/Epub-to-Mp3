//
//  ChapterListRowModelTests.swift
//  EpubToMp3Tests
//
//  Pure row-mapping coverage for the UIKit chapter list
//  (ChapterListCollectionView), now the default renderer on iOS/iPadOS.
//

import XCTest
@testable import EpubToMp3

final class ChapterListRowModelTests: XCTestCase {

    private func chapter(
        index: Int,
        name: String? = "Chapter",
        status: String? = nil,
        chars: Int? = nil,
        durationSeconds: Double? = nil
    ) -> JobSnapshot.Chapter {
        JobSnapshot.Chapter(
            index: index,
            name: name,
            status: status,
            downloadUrl: nil,
            chars: chars,
            charsProcessed: nil,
            progressRatio: nil,
            durationSeconds: durationSeconds,
            startedAt: nil,
            completedAt: nil
        )
    }

    func testRowsPreserveOrderAndTitle() {
        let chapters = [chapter(index: 0, name: "Intro"), chapter(index: 1, name: "Chapter One")]
        let rows = ChapterListRowModel.rows(from: chapters)
        XCTAssertEqual(rows.map(\.id), [0, 1])
        XCTAssertEqual(rows.map(\.title), ["Intro", "Chapter One"])
    }

    func testCharsTextOmittedWhenZeroOrNil() {
        let rows = ChapterListRowModel.rows(from: [
            chapter(index: 0, chars: 0),
            chapter(index: 1, chars: nil),
            chapter(index: 2, chars: 4200),
        ])
        XCTAssertNil(rows[0].charsText)
        XCTAssertNil(rows[1].charsText)
        XCTAssertNotNil(rows[2].charsText)
    }

    func testDurationTextFormatsMinutesSeconds() {
        let rows = ChapterListRowModel.rows(from: [chapter(index: 0, durationSeconds: 125)])
        XCTAssertEqual(rows[0].durationText, "2:05")
    }

    func testDurationTextOmittedWhenZeroOrNil() {
        let rows = ChapterListRowModel.rows(from: [
            chapter(index: 0, durationSeconds: 0),
            chapter(index: 1, durationSeconds: nil),
        ])
        XCTAssertNil(rows[0].durationText)
        XCTAssertNil(rows[1].durationText)
    }

    func testIsCompletedMirrorsChapterState() {
        let rows = ChapterListRowModel.rows(from: [
            chapter(index: 0, status: "completed"),
            chapter(index: 1, status: "queued"),
        ])
        XCTAssertTrue(rows[0].isCompleted)
        XCTAssertFalse(rows[1].isCompleted)
    }

    func testAccessibilityLabelCombinesTitleCompletionDuration() {
        let row = ChapterListRowModel(
            id: 0, title: "Intro", charsText: nil, durationText: "2:05", isCompleted: true
        )
        XCTAssertTrue(row.accessibilityLabel.contains("Intro"))
        XCTAssertTrue(row.accessibilityLabel.contains("2:05"))
    }

    func testFormatDurationPadsSeconds() {
        XCTAssertEqual(ChapterListRowModel.formatDuration(65), "1:05")
        XCTAssertEqual(ChapterListRowModel.formatDuration(5), "0:05")
    }
}
