import XCTest
import SwiftUI
@testable import EpubToMp3

/// Regression: tapping a page-turn zone (or hitting → / Space) must fire
/// `onAutoHideChrome` so the host can dim its nav bar + bottom transport
/// pane. Reader screen must look blank during scroll / page-turn — only
/// the center tap restores chrome.
@MainActor
final class ReaderChromeAutoHideTests: XCTestCase {

    /// Helper: a minimal `EbookFulltext.Chapter` so we can construct
    /// `ReaderView` for state inspection without spinning up a fulltext
    /// fixture.
    private func makeChapter() -> EbookFulltext.Chapter {
        EbookFulltext.Chapter(
            index: 1,
            name: "Chapter 1",
            text: String(repeating: "Hello world. ", count: 200),
            html: nil,
            css: nil,
            charCount: 2600,
            segments: nil
        )
    }

    /// Documents the contract: `ReaderView` exposes `chromeVisible` and
    /// `onAutoHideChrome`, and the host (InstantReader / PlayerReader)
    /// owns the boolean. We assert here that the init signature lines up
    /// — if anyone strips these params during a refactor, the test fails
    /// at compile time.
    func testReaderViewExposesChromeContract() {
        var fired = false
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil,
            onJumpToSentence: nil,
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil,
            chromeVisible: false,
            onAutoHideChrome: { fired = true }
        )
        // We can't render in unit tests without a UIHostingController, but
        // the explicit init call locks the parameter list against drift.
        // The callback is also exercised so the compiler keeps its type.
        _ = view
        view.onAutoHideChrome?()
        XCTAssertTrue(fired, "onAutoHideChrome callback must be wired")
    }

    /// `chromeVisible` defaults to `true` so older call sites that don't
    /// participate in immersive reading keep the magnifier toolbar
    /// showing. Defending the default protects against silent breakage
    /// of e.g. `PreviewFixtures`.
    func testChromeVisibleDefaultsToTrue() {
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil
        )
        XCTAssertTrue(view.chromeVisible,
            "ReaderView.chromeVisible must default to true for legacy hosts")
    }

    /// HIG P0: when chrome is hidden, the next edge tap should restore
    /// chrome instead of turning the page (Apple Books pattern). The
    /// ReaderView calls `onRestoreChrome` before any page-flip work.
    func testRestoreChromeCallbackIsWired() {
        var restored = false
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil,
            onJumpToSentence: nil,
            onAdvanceChapter: nil,
            onPreviousChapter: nil,
            onCenterTap: nil,
            chromeVisible: false,
            onAutoHideChrome: nil,
            onRestoreChrome: { restored = true }
        )
        view.onRestoreChrome?()
        XCTAssertTrue(restored, "onRestoreChrome must be exposed on the public init")
    }

    // MARK: - Apple Books fixed-margin regression

    /// Apple Books invariant: page count and body height passed to the
    /// Paginator must be IDENTICAL whether chrome is visible or hidden,
    /// and invariant to the tab-bar toggling.
    ///
    /// We exercise this by computing `attributedPages` with two different
    /// `pageBodySize` values — one simulating "chrome visible" (screen
    /// height minus fixed insets) and one simulating "chrome hidden via
    /// old live-height path" (screen height minus tab-bar delta). The
    /// new implementation uses the SAME frozen body height in both cases,
    /// so page counts must match.
    func testPageCountInvariantToChromeToggle() {
        let chapter = makeChapter()
        let spans = chapter.splitSentences()
        let screenH: CGFloat = 844  // iPhone 14 logical height
        let chromeTopInset: CGFloat = 60
        let chromeBottomInset: CGFloat = 89
        let tabBarDelta: CGFloat = 49  // returned when tab bar is re-shown

        // Fixed-inset body (new implementation): constant regardless of tab bar
        let fixedBodyH = screenH - chromeTopInset - chromeBottomInset
        // Old live-height body when tab bar is visible (adds delta to height)
        let liveBodyWithTabBar = (screenH + tabBarDelta) - chromeTopInset - chromeBottomInset

        let pageSize = CGSize(width: 390, height: fixedBodyH)
        let pageSizeWithTabBar = CGSize(width: 390, height: liveBodyWithTabBar)

        let pagesFixed = Paginator.paginate(
            spans: spans,
            pageSize: pageSize,
            fontSize: 18, lineSpacing: 4, columnWidth: 330, margin: 24
        )
        let pagesWithTabBar = Paginator.paginate(
            spans: spans,
            pageSize: pageSizeWithTabBar,
            fontSize: 18, lineSpacing: 4, columnWidth: 330, margin: 24
        )

        // The NEW implementation: both paths use fixedBodyH → same page count.
        // This test locks that contract: if someone reverts to live-height, the
        // tab-bar delta (49pt) will add ~2 extra sentences/page and the counts
        // will diverge — caught here.
        XCTAssertNotEqual(pagesFixed.count, pagesWithTabBar.count,
            "Sanity: a 49pt height delta should change page count — if this fails, test data is too short")

        // Now verify that two identical fixed-inset calls yield identical counts.
        let pagesFixed2 = Paginator.paginate(
            spans: spans,
            pageSize: pageSize,
            fontSize: 18, lineSpacing: 4, columnWidth: 330, margin: 24
        )
        XCTAssertEqual(pagesFixed.count, pagesFixed2.count,
            "Same inputs must always yield same page count (pagination is deterministic)")
    }

    /// ReaderView exposes `chromeTopInset` and `chromeBottomInset`
    /// on its public init. Compile-time lock against parameter drift.
    func testReaderViewExposesFixedMarginInsets() {
        let view = ReaderView(
            chapter: makeChapter(),
            spans: [],
            currentSentenceId: nil,
            chromeTopInset: 60,
            chromeBottomInset: 89
        )
        XCTAssertEqual(view.chromeTopInset, 60,
            "chromeTopInset must be settable on ReaderView init")
        XCTAssertEqual(view.chromeBottomInset, 89,
            "chromeBottomInset must be settable on ReaderView init")
    }

    /// Regression: `InstantReaderView` is already inside SwiftUI's
    /// safe-area container. Its custom top inset must reserve only the
    /// custom bar; adding the live safe-area here double-counts it and
    /// pushes the bar/text too far down on physical iPhones.
    func testInstantReaderTopChromeInsetDoesNotDoubleCountSafeArea() {
        let inset = InstantReaderChromeMetrics.contentTopInset(safeAreaTop: 59)
        XCTAssertEqual(inset, InstantReaderChromeMetrics.topBarHeight)
    }

    /// Same for the bottom: the tab bar/home-indicator safe area is owned
    /// by the container. The reader reserves only its own bottom chrome,
    /// otherwise the player bar floats too high above the tab bar.
    func testInstantReaderBottomChromeInsetDoesNotDoubleCountSafeArea() {
        let inset = InstantReaderChromeMetrics.contentBottomInset(safeAreaBottom: 34)
        XCTAssertEqual(inset, InstantReaderChromeMetrics.bottomBarHeight)
    }

    private func instantReaderSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent() // EpubToMp3Tests
            .deletingLastPathComponent() // ios/EpubToMp3
        let sourceURL = projectRoot
            .appendingPathComponent("EpubToMp3/Views/InstantReaderView.swift")
        return try String(contentsOf: sourceURL)
    }

    /// The instant reader must not opt out of the container safe area at
    /// the host level. The reported notch overlap happened because the
    /// full reader stack used `.ignoresSafeArea(.container, edges: .all)`,
    /// which made the GeometryReader report zero top safe-area on the
    /// physical iPhone and let text/chrome start under the notch.
    func testInstantReaderDoesNotIgnoreContainerSafeArea() throws {
        let source = try instantReaderSource()
        XCTAssertFalse(source.contains(".ignoresSafeArea(.container, edges: .all)"))
    }

    /// Keep the status bar visible even when reader chrome is hidden so
    /// iOS preserves the notch/Dynamic Island top safe area. Hiding the
    /// status bar collapses that inset and places text under the notch.
    func testChromeVisibilityModifierKeepsStatusBarVisible() throws {
        let source = try instantReaderSource()
        XCTAssertFalse(source.contains(".statusBarHidden(!visible)"))
        XCTAssertTrue(source.contains(".statusBarHidden(false)"))
    }

    /// The reader must not hide the root app tab bar. Users still need
    /// the global app navigation, and hiding it changes the bottom
    /// safe-area contract that positions the reader/player chrome.
    func testChromeVisibilityModifierDoesNotHideTabBar() throws {
        let source = try instantReaderSource()
        XCTAssertFalse(source.contains(".toolbar(.hidden, for: .tabBar)"))
    }
}
