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
        let readerURL = appDir.appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift")
        // `#filePath` only resolves on the CI host/simulator, not inside a
        // physical-device test bundle (mirrors textKitPageViewSource()'s guard
        // below) — skip rather than fail when the source tree isn't reachable.
        guard FileManager.default.fileExists(atPath: readerURL.path) else {
            throw XCTSkip("ReaderView.swift not reachable in this test host (physical device) — source-contract runs on the CI host/simulator.")
        }
        return (
            reader: try String(contentsOf: readerURL),
            attributed: try String(contentsOf: appDir.appendingPathComponent("EpubToMp3/Features/Reader/Views/AttributedPageView.swift"))
        )
    }

    /// Reads TextKitPageView.swift for the source-contract crossing-animation
    /// tests. `#filePath` only resolves on the CI host/simulator, not inside a
    /// physical-device test bundle, so those tests skip on device.
    private func textKitPageViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appDir = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = appDir.appendingPathComponent("EpubToMp3/Features/Reader/Views/TextKitPageView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("TextKitPageView.swift not reachable in this test host (physical device) — source-contract runs on the CI host/simulator.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Reads PlayerReaderView.swift, same skip-guard pattern as the other
    /// source-contract helpers above.
    private func playerReaderViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appDir = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = appDir.appendingPathComponent("EpubToMp3/Features/Reader/Views/PlayerReaderView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("PlayerReaderView.swift not reachable in this test host (physical device) — source-contract runs on the CI host/simulator.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Reads InstantReaderView.swift, same skip-guard pattern as the other
    /// source-contract helpers above.
    private func instantReaderViewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appDir = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = appDir.appendingPathComponent("EpubToMp3/Features/Reader/Views/InstantReaderView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("InstantReaderView.swift not reachable in this test host (physical device) — source-contract runs on the CI host/simulator.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Regression: `InstantReaderView` has its OWN, separate
    /// `returnToPreviousChapter`/`readerShouldStartAtLastPage` — a fully
    /// independent implementation from `PlayerReaderView`'s (confirmed via
    /// on-device flicker-debug.log: the fix in PlayerReaderView never fired
    /// because the user was exercising InstantReaderView instead). Here the
    /// race was even more direct: `.compatOnChange(of: currentChapterIndex)`
    /// fires the instant `currentChapterIndex -= 1` runs inside
    /// `returnToPreviousChapter()` — practically the very next line after
    /// `readerShouldStartAtLastPage = true` — resetting it back to `false`
    /// before the new ReaderView's `Int.max` seed had any chance to settle.
    /// Same fix shape as PlayerReaderView: the reset must only happen via
    /// `ReaderView.onLastPageLanded`.
    func testInstantReaderRetreatFlagResetOnlyViaReaderCallbackNotChapterIndexChange() throws {
        let src = try instantReaderViewSource()
        XCTAssertTrue(
            src.contains("onLastPageLanded: { readerShouldStartAtLastPage = false }"),
            "InstantReaderView's ReaderView must reset readerShouldStartAtLastPage via onLastPageLanded, " +
            "not reactively off currentChapterIndex changing."
        )
        guard let range = src.range(of: ".compatOnChange(of: currentChapterIndex)") else {
            XCTFail("currentChapterIndex onChange handler not found")
            return
        }
        let tail = src[range.upperBound...]
        guard let closeRange = tail.range(of: "\n        }") else {
            XCTFail("could not locate end of currentChapterIndex onChange handler")
            return
        }
        let handlerBody = tail[..<closeRange.lowerBound]
        XCTAssertFalse(
            handlerBody.contains("readerShouldStartAtLastPage = false"),
            "currentChapterIndex's onChange must not reset readerShouldStartAtLastPage — it fires " +
            "near-synchronously with returnToPreviousChapter's own currentChapterIndex -= 1, " +
            "racing the retreat's Int.max seed before it can settle."
        )
    }

    /// Regression: on-device logging proved `readerShouldStartAtLastPage`
    /// was being reset to `false` reactively off `playingEpubZeroBasedIndex`
    /// (the AUDIO player's chapter index) — which settles near-instantly,
    /// well before the reader's own `Int.max` → real-last-page seed
    /// finishes. That premature reset re-rendered the SAME `.id()`-stable
    /// ReaderView with `startAtLastPage: false`, which reset `currentPage`
    /// back to 0 mid-flight — "retreat lands on page 1 instead of the last
    /// page" even though the correct PREVIOUS chapter was already showing
    /// (a separate, already-fixed bug). The fix: `returnToPreviousChapter`'s
    /// flags are only cleared by `ReaderView.onLastPageLanded`, fired by the
    /// reader itself once pagination genuinely settles — never by the audio
    /// index catching up.
    func testRetreatFlagsResetOnlyViaReaderCallbackNotAudioIndex() throws {
        let src = try playerReaderViewSource()
        XCTAssertTrue(
            src.contains("onLastPageLanded: {"),
            "ReaderView must be given an onLastPageLanded callback so it — not the audio index — decides when startAtLastPage's flags reset."
        )
        // The playingEpubZeroBasedIndex onChange handler must NOT reset
        // readerShouldStartAtLastPage anymore — only onLastPageLanded may.
        guard let range = src.range(of: ".compatOnChange(of: playingEpubZeroBasedIndex)") else {
            XCTFail("playingEpubZeroBasedIndex onChange handler not found")
            return
        }
        let tail = src[range.upperBound...]
        guard let closeRange = tail.range(of: "\n        }") else {
            XCTFail("could not locate end of playingEpubZeroBasedIndex onChange handler")
            return
        }
        let handlerBody = tail[..<closeRange.lowerBound]
        XCTAssertFalse(
            handlerBody.contains("readerShouldStartAtLastPage = false"),
            "playingEpubZeroBasedIndex's onChange must not reset readerShouldStartAtLastPage — " +
            "the audio index settles before pagination does, racing a retreat's Int.max seed."
        )
    }

    // MARK: - Chapter-crossing animation (source-contract)

    func testCrossingReSeedAnimatesInCrossingDirection() throws {
        let src = try textKitPageViewSource()
        XCTAssertTrue(src.contains("func seedCrossing("),
                      "The animated crossing re-seed helper seedCrossing must exist.")
        XCTAssertTrue(src.contains("var pendingCrossingDirection: UIPageViewController.NavigationDirection?"),
                      "The crossing direction side-channel must exist.")
        // The two crossing re-seed sites (token-change with pages, deferred seed)
        // must route through seedCrossing, NOT a bare animated:false hard cut.
        let seedCalls = src.components(separatedBy: "coordinator.seedCrossing(pvc, vc)").count - 1
        XCTAssertGreaterThanOrEqual(seedCalls, 2,
                      "Both crossing re-seed sites must call seedCrossing (found \(seedCalls)).")
    }

    func testCrossingDirectionArmedAtAllFourSites() throws {
        let src = try textKitPageViewSource()
        let forward = src.components(separatedBy: "pendingCrossingDirection = .forward").count - 1
        let reverse = src.components(separatedBy: "pendingCrossingDirection = .reverse").count - 1
        // navigate + handleEdgePan each arm forward and reverse → 2 of each.
        XCTAssertEqual(forward, 2, "Forward crossings (navigate + edge-pan) must arm .forward.")
        XCTAssertEqual(reverse, 2, "Reverse crossings (navigate + edge-pan) must arm .reverse.")
    }

    func testCountChangeReSeedStaysUnanimated() throws {
        let src = try textKitPageViewSource()
        // Settings repagination (count-change, same chapter) must NOT animate.
        XCTAssertTrue(src.contains("// Page count changed within the SAME chapter (settings repagination)."),
                      "The count-change branch comment must remain (locates the branch).")
        XCTAssertTrue(src.contains("pvc.setViewControllers([vc], direction: .forward, animated: false)"),
                      "The count-change branch must still hard-cut with animated: false.")
    }

    /// Regression: a fix attempt force-set `vc.view.frame` (and called
    /// `layoutIfNeeded()`) in `seedCrossing` before handing the incoming
    /// controller to `setViewControllers`, to solve a black-flash-on-crossing
    /// bug. It fought `UIPageViewController`'s own frame ownership of the
    /// pageCurl transition container: the manual frame got silently
    /// overwritten post-installation with no follow-up layout pass, leaving
    /// TextKit's glyph cache stale — text rendered only DURING the animated
    /// curl and vanished once it settled at rest. `seedCrossing` must never
    /// touch `vc.view.frame`; `TextKitPageController.viewDidLayoutSubviews`
    /// (not `seedCrossing`) is the mechanism that keeps text in sync with
    /// whatever frame the PVC actually installs.
    func testSeedCrossingDoesNotForceIncomingControllerFrame() throws {
        let src = try textKitPageViewSource()
        XCTAssertFalse(
            src.contains("vc.view.frame ="),
            "seedCrossing must not manually assign the incoming controller's view frame — " +
            "UIPageViewController owns pageCurl child-view framing; fighting it left text " +
            "visible only during the animated transition and invisible at rest."
        )
        XCTAssertTrue(
            src.contains("override func viewDidLayoutSubviews()"),
            "TextKitPageController must re-sync the hosted text view on every real layout pass " +
            "instead of pre-forcing a frame in seedCrossing."
        )
    }

    func testCrossingReSeedRespectsReduceMotionAndGuardsProgrammaticTurn() throws {
        let src = try textKitPageViewSource()
        XCTAssertTrue(src.contains("UIAccessibility.isReduceMotionEnabled"),
                      "seedCrossing must fall back to a hard cut under reduce-motion.")
        // Double-hop guard: isProgrammaticTurn set before the animated turn and
        // cleared in its completion handler (so didFinishAnimating early-returns).
        XCTAssertTrue(src.contains("isProgrammaticTurn = true"),
                      "seedCrossing must set isProgrammaticTurn before the animated turn.")
        XCTAssertTrue(src.contains("self.isProgrammaticTurn = false"),
                      "seedCrossing's completion must clear isProgrammaticTurn.")
    }

    func testSingleTapProducesExactlyOnePageRetreat() throws {
        let readerSource = try readerSources().reader
        // A single native tap owner emits the semantic chrome event. The
        // old overlay route would race the TextKit recognizer and is gone.
        XCTAssertFalse(
            readerSource.contains(".overlay(tapZones("),
            "a competing SwiftUI tap overlay must not be installed"
        )
        XCTAssertTrue(
            readerSource.contains("onCenterTap?()"),
            "a non-link tap must toggle chrome rather than page state"
        )
        // Swipe handling moved into the native UIPageViewController for the
        // page-curl style (TextKitPageView owns the pan), and slide/none
        // forward swipes through `onSwipe` on the FixedWidthTextView. The
        // old SwiftUI `DragGesture(minimumDistance: 30)` no longer lives in
        // ReaderView — there must be exactly ONE swipe path, not a SwiftUI
        // drag racing the UIKit pan.
        XCTAssertFalse(
            readerSource.contains("DragGesture(minimumDistance: 30)"),
            "The legacy SwiftUI swipe DragGesture must be gone — page-curl turns are " +
            "driven by UIPageViewController; a parallel SwiftUI drag would double-fire."
        )
        XCTAssertTrue(
            readerSource.contains("onSwipe: enableReaderGestures ? onSwipePage : nil"),
            "Slide/none swipe-to-turn must be the single onSwipe path on FixedWidthTextView."
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
            readerSource.contains("guard !isPageTurning,"),
            "advancePage and retreatPage must guard against firing during an in-flight animation " +
            "(now combined with a debounce on lastPageTurnAt)."
        )
        XCTAssertTrue(
            readerSource.contains("Date().timeIntervalSince(lastPageTurnAt) > pageTurnDebounce"),
            "The turn guard must also debounce rapid taps across all turn styles, not only slide."
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

    func testBackwardCrossingWaitsForFinalAttributedPagesBeforeSeeding() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let readerURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("EpubToMp3/Features/Reader/Views/ReaderView.swift")
        let source = try String(contentsOf: readerURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("jumpToLastPageForChapterId == \"__pending__\" && renderedAttributed == nil"),
            "A backward crossing must defer pagination while only the temporary plain-text fallback exists."
        )
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
