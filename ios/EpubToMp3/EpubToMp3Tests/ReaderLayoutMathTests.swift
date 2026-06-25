import XCTest
import CoreGraphics
@testable import EpubToMp3

/// Tests for the paginated reader's safe-area / corridor math. Regression
/// for "paginated still ignores the safe area — text under the clock /
/// battery". The page controller pins to raw view edges, so these insets
/// MUST fold in SwiftUI's safe-area values; if they don't, text renders
/// under the status bar on every page.
final class ReaderLayoutMathTests: XCTestCase {

    /// iPhone with a notch, chrome HIDDEN (chromeTop == 0): the corridor
    /// must STILL reserve the status-bar safe area so text clears the clock.
    func testTopCorridorReservesSafeAreaWhenChromeHidden() {
        let corridor = ReaderLayoutMath.topCorridor(
            safeAreaTop: 59, chromeTop: 0, pad: 12, hiddenCompaction: 0
        )
        XCTAssertGreaterThanOrEqual(corridor, 59,
            "with chrome hidden the corridor must still clear the status bar / notch")
    }

    /// THE BUG: chrome hidden applies a large compaction (72 pt) to reclaim
    /// the chrome band — but that compaction must NEVER eat the safe area. On
    /// a 59 pt-notch phone the old formula `safeAreaTop + chromeTop + pad -
    /// hiddenCompaction` = 59 + 0 + 12 - 72 = -1 → clamped to 0 → the first
    /// line rendered under the clock. The safe area must remain a hard floor.
    func testTopCorridorKeepsSafeAreaWhenChromeHiddenWithCompaction() {
        let corridor = ReaderLayoutMath.topCorridor(
            safeAreaTop: 59, chromeTop: 0, pad: 12, hiddenCompaction: 72
        )
        XCTAssertGreaterThanOrEqual(corridor, 59,
            "compaction must only shrink the chrome reserve, never the safe area")
    }

    /// Compaction shrinks the chrome reserve but the corridor is still at
    /// least the safe area; with chrome visible and no compaction the reserve
    /// is fully present on top of the safe area.
    func testTopCorridorCompactsOnlyChromeReserve() {
        // Hidden: reserve collapses, safe area intact.
        XCTAssertEqual(
            ReaderLayoutMath.topCorridor(safeAreaTop: 47, chromeTop: 8, pad: 12, hiddenCompaction: 72),
            47, accuracy: 0.001)
        // Visible: safe area + (chrome 8 + pad 12).
        XCTAssertEqual(
            ReaderLayoutMath.topCorridor(safeAreaTop: 47, chromeTop: 8, pad: 12, hiddenCompaction: 0),
            47 + 20, accuracy: 0.001)
    }

    /// Chrome VISIBLE: corridor is safe area + chrome + pad.
    func testTopCorridorAddsChromeOnTopOfSafeArea() {
        let corridor = ReaderLayoutMath.topCorridor(
            safeAreaTop: 59, chromeTop: 44, pad: 12, hiddenCompaction: 0
        )
        XCTAssertEqual(corridor, 59 + 44 + 12, accuracy: 0.001)
    }

    /// Bottom corridor reserves the home indicator + chrome + footer + pad.
    func testBottomCorridorReservesHomeIndicatorAndFooter() {
        let corridor = ReaderLayoutMath.bottomCorridor(
            safeAreaBottom: 34, chromeBottom: 0, footer: 30, pad: 12
        )
        XCTAssertEqual(corridor, 34 + 30 + 12, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(corridor, 34, "must clear the home indicator")
    }

    /// A device with no safe area (older iPhone / iPad) still gets the pad
    /// and never a negative corridor.
    func testCorridorsNonNegativeWithoutSafeArea() {
        XCTAssertGreaterThanOrEqual(
            ReaderLayoutMath.topCorridor(safeAreaTop: 0, chromeTop: 0, pad: 12, hiddenCompaction: 72), 0)
        XCTAssertEqual(
            ReaderLayoutMath.bottomCorridor(safeAreaBottom: 0, chromeBottom: 0, footer: 0, pad: 12),
            12, accuracy: 0.001)
    }

    /// On a phone the column fills `width - 2*margin`, so the side inset is
    /// exactly the margin — text is NOT squeezed into a narrow centred
    /// column (the "tudo centralizado" report).
    func testSideInsetIsMarginWhenColumnFillsWidth() {
        let width: CGFloat = 393
        let margin: CGFloat = 24
        let columnWidth = width - 2 * margin // 345 — column fills the phone
        let inset = ReaderLayoutMath.sideInset(containerWidth: width, columnWidth: columnWidth, margin: margin)
        XCTAssertEqual(inset, margin, accuracy: 0.001,
            "a full-width column must not be centred into a narrow strip on a phone")
    }

    /// On a wide iPad the column is narrower than the container, so the
    /// inset centres it (and exceeds the bare margin).
    func testSideInsetCentresNarrowColumnOnWideContainer() {
        let inset = ReaderLayoutMath.sideInset(containerWidth: 1024, columnWidth: 720, margin: 24)
        XCTAssertEqual(inset, (1024 - 720) / 2, accuracy: 0.001)
        XCTAssertGreaterThan(inset, 24)
    }
}
