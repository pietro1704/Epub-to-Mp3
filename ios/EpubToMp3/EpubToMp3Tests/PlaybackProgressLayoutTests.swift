//
//  PlaybackProgressLayoutTests.swift
//  EpubToMp3Tests
//
//  Pure fraction/segment math coverage for the CADisplayLink-driven UIKit
//  progress bars (PlaybackProgressBar / SegmentedPlaybackProgressBar), now
//  the default renderer on iOS/iPadOS in MiniPlayerBar + FullPlayerSheet.
//

import XCTest
@testable import EpubToMp3

final class PlaybackProgressLayoutTests: XCTestCase {

    // MARK: - fraction

    func testFractionComputesRatio() {
        XCTAssertEqual(PlaybackProgressLayout.fraction(position: 30, duration: 120), 0.25)
    }

    func testFractionClampsAboveOne() {
        XCTAssertEqual(PlaybackProgressLayout.fraction(position: 200, duration: 120), 1)
    }

    func testFractionClampsBelowZero() {
        XCTAssertEqual(PlaybackProgressLayout.fraction(position: -10, duration: 120), 0)
    }

    func testFractionZeroWhenDurationZero() {
        XCTAssertEqual(PlaybackProgressLayout.fraction(position: 30, duration: 0), 0)
    }

    func testFractionZeroWhenNonFinite() {
        XCTAssertEqual(PlaybackProgressLayout.fraction(position: .nan, duration: 120), 0)
        XCTAssertEqual(PlaybackProgressLayout.fraction(position: 30, duration: .infinity), 0)
    }

    // MARK: - segments

    private func snapshot(chapters: [(index: Int, status: String, chars: Int, downloadUrl: String?)]) -> JobSnapshot {
        JobSnapshot(
            jobId: "job", state: "running", bookTitle: "Book", bookAuthor: nil,
            coverUrl: nil, coverMimeType: nil, engine: nil, voice: nil, language: nil,
            progressPercent: nil, chaptersTotal: chapters.count, chaptersCompleted: nil,
            chapterProgress: chapters.map { c in
                JobSnapshot.Chapter(
                    index: c.index, name: "Chapter \(c.index)", status: c.status,
                    downloadUrl: c.downloadUrl, chars: c.chars, charsProcessed: nil,
                    progressRatio: nil, durationSeconds: nil, startedAt: nil, completedAt: nil
                )
            },
            outputs: nil, logUrl: nil, error: nil, lastActivityAt: nil
        )
    }

    func testSegmentsEmptyWhenNoChapters() {
        let progress = BookChapterProgress(snapshot: nil)
        let segments = PlaybackProgressLayout.segments(
            for: progress, totalWidth: 300, height: 4, currentPlayableIndex: nil
        )
        XCTAssertTrue(segments.isEmpty)
    }

    func testSegmentsEmptyWhenWidthZero() {
        let progress = BookChapterProgress(snapshot: snapshot(chapters: [(0, "completed", 100, "a.mp3")]))
        let segments = PlaybackProgressLayout.segments(
            for: progress, totalWidth: 0, height: 4, currentPlayableIndex: nil
        )
        XCTAssertTrue(segments.isEmpty)
    }

    func testSegmentsWeightedByChars() {
        let progress = BookChapterProgress(snapshot: snapshot(chapters: [
            (0, "completed", 100, "a.mp3"),
            (1, "completed", 300, "b.mp3"),
        ]))
        let segments = PlaybackProgressLayout.segments(
            for: progress, totalWidth: 400, height: 4, currentPlayableIndex: nil
        )
        XCTAssertEqual(segments.count, 2)
        // Chapter 0 has 1/4 the weight of chapter 1's total (100 vs 300 of 400).
        XCTAssertEqual(segments[0].frame.width, 100, accuracy: 0.01)
        XCTAssertEqual(segments[1].frame.width, 300, accuracy: 0.01)
        // Laid left to right with a 1pt gutter.
        XCTAssertEqual(segments[1].frame.minX, segments[0].frame.maxX + 1, accuracy: 0.01)
    }

    func testSegmentsFlagsCurrentPlayableChapter() {
        let progress = BookChapterProgress(snapshot: snapshot(chapters: [
            (0, "completed", 100, "a.mp3"),
            (1, "running", 100, "b.mp3"),
        ]))
        let segments = PlaybackProgressLayout.segments(
            for: progress, totalWidth: 200, height: 4, currentPlayableIndex: 1
        )
        XCTAssertFalse(segments[0].isCurrent)
        XCTAssertTrue(segments[1].isCurrent)
    }

    func testSegmentsFloorWidthAtTwoPoints() {
        // 100 chapters sharing a narrow 50pt bar — each would compute to
        // < 2pt without the floor.
        let chapters = (0..<100).map { (index: $0, status: "queued", chars: 1, downloadUrl: Optional<String>.none) }
        let progress = BookChapterProgress(snapshot: snapshot(chapters: chapters))
        let segments = PlaybackProgressLayout.segments(
            for: progress, totalWidth: 50, height: 4, currentPlayableIndex: nil
        )
        XCTAssertTrue(segments.allSatisfy { $0.frame.width >= 2 })
    }
}
