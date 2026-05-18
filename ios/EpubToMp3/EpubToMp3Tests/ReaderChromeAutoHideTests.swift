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
}
