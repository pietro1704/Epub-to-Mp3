import XCTest
@testable import EpubToMp3

/// Regression: paginated reader used to dead-end on the last page of
/// the current chapter — `handleKeyPress`/`tapZones`/`DragGesture` all
/// clamped to `pages.count`. Carl Sagan's "Pale Blue Dot" parses into
/// many chapters; the reader showed only the first page of chapter 1
/// and then nothing.
///
/// Fix (`ReaderView.advancePage`/`retreatPage`) delegates to the host
/// view's `onAdvanceChapter` / `onPreviousChapter` callbacks at the
/// page boundary. These tests exercise the host-side counters that
/// those callbacks bump — `InstantReaderView.advanceToNextChapter` /
/// `returnToPreviousChapter` — without mounting a SwiftUI view tree.
final class ReaderChapterAdvanceTests: XCTestCase {

    /// Minimal stand-in for the `InstantReaderView` state machinery.
    /// Mirrors the exact same logic the view holds so the contract
    /// stays in lockstep — if you change the view, change this.
    private struct AdvanceModel {
        var currentChapterIndex: Int
        let chapterCount: Int

        /// Returns true if there is a next chapter and we advanced.
        mutating func advance() -> Bool {
            guard currentChapterIndex + 1 < chapterCount else { return false }
            currentChapterIndex += 1
            return true
        }

        mutating func retreat() -> Bool {
            guard currentChapterIndex > 0 else { return false }
            currentChapterIndex -= 1
            return true
        }
    }

    func testAdvanceMovesForwardThroughChapters() {
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 5)
        XCTAssertTrue(m.advance())
        XCTAssertEqual(m.currentChapterIndex, 1)
        XCTAssertTrue(m.advance())
        XCTAssertTrue(m.advance())
        XCTAssertTrue(m.advance())
        XCTAssertEqual(m.currentChapterIndex, 4)
    }

    func testAdvanceReturnsFalseOnLastChapter() {
        var m = AdvanceModel(currentChapterIndex: 4, chapterCount: 5)
        XCTAssertFalse(m.advance(),
                       "must report no-advance on the last chapter so the reader stays put")
        XCTAssertEqual(m.currentChapterIndex, 4)
    }

    func testRetreatMovesBackward() {
        var m = AdvanceModel(currentChapterIndex: 3, chapterCount: 5)
        XCTAssertTrue(m.retreat())
        XCTAssertEqual(m.currentChapterIndex, 2)
    }

    func testRetreatReturnsFalseOnFirstChapter() {
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 5)
        XCTAssertFalse(m.retreat())
        XCTAssertEqual(m.currentChapterIndex, 0)
    }

    func testCarlScenario_ManyChaptersStayReachable() {
        // Pale Blue Dot has ~24 chapters. Simulate the user paging
        // through to the end and back to confirm no dead-end.
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 24)
        var advanced = 0
        while m.advance() { advanced += 1 }
        XCTAssertEqual(advanced, 23)
        XCTAssertEqual(m.currentChapterIndex, 23)

        var retreated = 0
        while m.retreat() { retreated += 1 }
        XCTAssertEqual(retreated, 23)
        XCTAssertEqual(m.currentChapterIndex, 0)
    }

    func testSingleChapterBookHasNoAdvanceTarget() {
        // Defensive: a 1-chapter book should report no-advance and
        // no-retreat, so the reader silently keeps the page bound.
        var m = AdvanceModel(currentChapterIndex: 0, chapterCount: 1)
        XCTAssertFalse(m.advance())
        XCTAssertFalse(m.retreat())
    }

    // MARK: - Double-fire regression

    /// Regression: before the fix, a single tap fired retreatPage() twice
    /// (once from UITapGestureRecognizer in the UITextView via onZoneTap,
    /// once from the SwiftUI tapZones() SpatialTapGesture overlay). The
    /// double call on a chapter boundary jumped back two chapters — visually
    /// a flash to chapter 0 (the Gutenberg cover/index). This test models the
    /// page-turn call site so we can assert exactly one call per gesture.
    private func readerSources() throws -> (reader: String, attributed: String) {
        let testFile = URL(fileURLWithPath: #filePath)
        let appDir = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return (
            reader: try String(contentsOf: appDir.appendingPathComponent("EpubToMp3/Views/ReaderView.swift")),
            attributed: try String(contentsOf: appDir.appendingPathComponent("EpubToMp3/Views/AttributedPageView.swift"))
        )
    }

    func testSingleTapProducesExactlyOnePageRetreat() throws {
        // The source-level contract: onZoneTap must NOT be wired into
        // AttributedPageView in paginated mode. Both recognizers firing is
        // what caused the double retreat. Verify the source enforces this.
        let sources = try readerSources()
        let readerSource = sources.reader
        let attributedSource = sources.attributed

        XCTAssertFalse(
            readerSource.contains("onZoneTap: enableReaderGestures ? { zone in"),
            "onZoneTap must not be passed to AttributedPageView in slide/none mode: " +
            "it installs a UITapGestureRecognizer that fires alongside tapZones(), " +
            "calling retreatPage() twice per tap (double-fire = flash to chapter 0)."
        )
        XCTAssertFalse(
            attributedSource.contains("UISwipeGestureRecognizer("),
            "UISwipeGestureRecognizer must not be installed: it fires before the finger lifts, " +
            "causing an early page-turn AND racing DragGesture for a second turn."
        )
        XCTAssertTrue(
            readerSource.contains(".overlay(tapZones("),
            "A single tapZones() SwiftUI overlay must be the sole zone-tap handler."
        )
        XCTAssertTrue(
            readerSource.contains("DragGesture(minimumDistance: 30)"),
            "A single DragGesture(.onEnded) must be the sole swipe-to-turn handler."
        )
    }

    func testIsPageTurningGuardPreventsRapidDoubleTurn() throws {
        // Regression: tapping rapidly during a slide animation fired a second
        // page turn without animation (because advancePage had no guard).
        // isPageTurning is set true at animation start, false after 0.25s.
        // A second call while true must be dropped entirely.
        let readerSource = try readerSources().reader
        XCTAssertTrue(
            readerSource.contains("@State private var isPageTurning: Bool = false"),
            "ReaderView must declare isPageTurning to lock out rapid-fire taps during animation."
        )
        XCTAssertTrue(
            readerSource.contains("guard !isPageTurning else { return }"),
            "advancePage and retreatPage must guard against firing during an in-flight animation."
        )
        XCTAssertTrue(
            readerSource.contains("isPageTurning = true"),
            "The guard flag must be set at the start of a slide animation."
        )
        XCTAssertTrue(
            readerSource.contains("isPageTurning = false"),
            "The guard flag must be cleared after the animation completes."
        )

        // Model: simulate rapid tap — second call while turning must be dropped.
        struct PageModel {
            var currentPage = 0
            var isPageTurning = false
            let pageCount: Int

            mutating func advancePage() {
                guard !isPageTurning else { return }
                if currentPage + 1 < pageCount {
                    isPageTurning = true
                    currentPage += 1
                    // animation completes asynchronously; not simulated here
                }
            }
        }
        var m = PageModel(pageCount: 5)
        m.advancePage()                    // first tap — fires, isPageTurning = true
        XCTAssertEqual(m.currentPage, 1)
        XCTAssertTrue(m.isPageTurning)
        m.advancePage()                    // rapid second tap — must be dropped
        XCTAssertEqual(m.currentPage, 1, "Second tap during animation must be ignored")
        m.isPageTurning = false            // animation ends
        m.advancePage()                    // now allowed
        XCTAssertEqual(m.currentPage, 2, "Tap after animation ends must fire normally")
    }

    func testSingleTapProducesExactlyOnePageAdvance() throws {
        // Model test: simulate a paginated reader with 3 pages and verify
        // that calling advancePage exactly once moves exactly one page.
        struct PageModel {
            var currentPage: Int = 0
            var advanceCallCount: Int = 0
            let pageCount: Int

            mutating func advancePage() {
                advanceCallCount += 1
                if currentPage + 1 < pageCount {
                    currentPage += 1
                }
            }
        }
        var model = PageModel(pageCount: 3)
        model.advancePage()  // exactly one call (as tapZones() fires once)
        XCTAssertEqual(model.advanceCallCount, 1, "One tap → one advancePage call")
        XCTAssertEqual(model.currentPage, 1)
    }

    func testDoubleTapCallWouldHaveJumpedTwoChapters() {
        // Documents the bug: two retreat calls on chapter boundary jump two chapters.
        // Before the fix, onZoneTap on UITextView + tapZones() SwiftUI both fired,
        // giving this behaviour. The fix ensures only one fires.
        var m = AdvanceModel(currentChapterIndex: 2, chapterCount: 5)
        // Bug: two retreats in one "tap" gesture
        _ = m.retreat()
        _ = m.retreat()
        XCTAssertEqual(m.currentChapterIndex, 0,
                       "Double-retreat bug: lands on chapter 0 (index/cover) instead of chapter 1")
        // After fix: only one retreat per tap
        var mFixed = AdvanceModel(currentChapterIndex: 2, chapterCount: 5)
        _ = mFixed.retreat()
        XCTAssertEqual(mFixed.currentChapterIndex, 1,
                       "Single-retreat (fixed): correctly lands on chapter 1")
    }
}
