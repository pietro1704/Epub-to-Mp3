import XCTest
@testable import EpubToMp3Core

final class SyncEngineTests: XCTestCase {

    // MARK: Segment-table mode

    func testWalksRealSegmentTable() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Ch", text: "A. B. C.",
            html: nil, css: nil, charCount: nil,
            segments: [
                EbookFulltext.Segment(id: "s0", text: "A.", startMs: 0,    endMs: 1000),
                EbookFulltext.Segment(id: "s1", text: "B.", startMs: 1000, endMs: 2000),
                EbookFulltext.Segment(id: "s2", text: "C.", startMs: 2000, endMs: 3000),
            ]
        )
        let engine = SyncEngine(wpm: 200)
        engine.load(chapter: chapter, chapterDurationSeconds: 3.0)

        XCTAssertEqual(engine.source, .segments)
        XCTAssertEqual(engine.update(positionSeconds: 0.5), "s0")
        XCTAssertEqual(engine.update(positionSeconds: 1.5), "s1")
        XCTAssertEqual(engine.update(positionSeconds: 2.999), "s2")
        // After the last segment ends, no current sentence.
        XCTAssertNil(engine.update(positionSeconds: 3.1))
    }

    // MARK: WPM fallback

    func testFallsBackToWPMWhenNoSegments() {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Ch",
            text: "Short. Much longer sentence to consume more time.",
            html: nil, css: nil, charCount: nil, segments: nil
        )
        let engine = SyncEngine(wpm: 200)
        engine.load(chapter: chapter, chapterDurationSeconds: 10.0)

        XCTAssertEqual(engine.source, .wpmEstimate)
        XCTAssertEqual(engine.timing.count, 2)
        // Char-proportional split: "Short." is 6 chars; the second
        // sentence is ~43 chars. The longer one should consume more
        // of the 10s budget.
        let firstDur = engine.timing[0].endMs - engine.timing[0].startMs
        let secondDur = engine.timing[1].endMs - engine.timing[1].startMs
        XCTAssertGreaterThan(secondDur, firstDur)

        XCTAssertEqual(engine.update(positionSeconds: 0.1), engine.timing[0].id)
        XCTAssertEqual(engine.update(positionSeconds: 9.5), engine.timing[1].id)
    }

    func testWPMEstimateWithoutDurationFallsBackToPureWPM() {
        let engine = SyncEngine(wpm: 200)
        let spans = [
            SentenceSpan(id: "0", text: "Five words make twenty chars.", startChar: 0, endChar: 29),
            SentenceSpan(id: "1", text: "Another short sentence here.",   startChar: 30, endChar: 58),
        ]
        let timing = engine.estimateTiming(spans: spans, durationSeconds: 0)
        XCTAssertEqual(timing.count, 2)
        XCTAssertEqual(timing[0].startMs, 0)
        // Cumulative — second entry must start where first ends.
        XCTAssertEqual(timing[1].startMs, timing[0].endMs)
        // Total duration should be > 0 even without an audio reference.
        XCTAssertGreaterThan(timing.last!.endMs, 0)
    }

    func testEmptyChapterProducesNoSentence() {
        let chapter = EbookFulltext.Chapter(
            index: 0, name: nil, text: "",
            html: nil, css: nil, charCount: 0, segments: nil
        )
        let engine = SyncEngine()
        engine.load(chapter: chapter, chapterDurationSeconds: 5)
        XCTAssertEqual(engine.source, .empty)
        XCTAssertNil(engine.update(positionSeconds: 1.0))
    }

    // MARK: Sentence-change stream

    func testStreamEmitsOnlyOnChange() async {
        let chapter = EbookFulltext.Chapter(
            index: 1, name: "Ch", text: "A. B.",
            html: nil, css: nil, charCount: nil,
            segments: [
                EbookFulltext.Segment(id: "s0", text: "A.", startMs: 0,    endMs: 1000),
                EbookFulltext.Segment(id: "s1", text: "B.", startMs: 1000, endMs: 2000),
            ]
        )
        let engine = SyncEngine()
        engine.load(chapter: chapter, chapterDurationSeconds: 2)

        var received: [String?] = []
        let collector = Task {
            for await id in engine.currentSentence {
                received.append(id)
                if received.count >= 3 { break }
            }
        }

        // Initial yield is `nil` (no current sentence yet).
        // Tick repeatedly within sentence 0 — should NOT emit again.
        _ = engine.update(positionSeconds: 0.1)
        _ = engine.update(positionSeconds: 0.2)
        _ = engine.update(positionSeconds: 0.3)
        // Cross into sentence 1 — should emit.
        _ = engine.update(positionSeconds: 1.5)
        // Past the end — should emit nil.
        _ = engine.update(positionSeconds: 2.5)

        _ = await collector.value
        // Expect: nil (initial), "s0", "s1" (the trailing nil arrives
        // only after the third yield broke the loop).
        XCTAssertEqual(received.prefix(3).map { $0 ?? "nil" }, ["nil", "s0", "s1"])
    }

    func testWPMConfigurableForSlowerEngines() {
        let engine = SyncEngine(wpm: 100) // half-speed (Piper-ish)
        let spans = [
            SentenceSpan(id: "0", text: "Hello world this is a sentence.", startChar: 0, endChar: 33)
        ]
        let fast = SyncEngine(wpm: 200).estimateTiming(spans: spans, durationSeconds: 0)
        let slow = engine.estimateTiming(spans: spans, durationSeconds: 0)
        XCTAssertGreaterThan(slow.first!.endMs, fast.first!.endMs)
    }
}
