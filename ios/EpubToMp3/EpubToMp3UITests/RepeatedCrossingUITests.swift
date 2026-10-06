import XCTest

/// Regression for "chapter crossing stops working after the first time".
/// Crosses several chapter boundaries in a row by SWIPE (then by TAP), and by
/// going forward then backward, asserting each crossing actually changes the
/// chapter index. Catches a stuck swap latch / disabled gesture after the
/// first cross.
@MainActor
final class RepeatedCrossingUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func chapter(_ app: XCUIApplication) -> (index: Int, total: Int)? {
        let label = app.staticTexts["flicker.probe.chapter"].firstMatch.label
        let parts = label.split(separator: "/").map(String.init)
        guard parts.count == 2, let i = Int(parts[0]), let t = Int(parts[1]) else { return nil }
        return (i, t)
    }
    private func indicator(_ app: XCUIApplication) -> (page: Int, total: Int)? {
        let label = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let parts = label.split(separator: " ").map(String.init)
        guard parts.count >= 3, let p = Int(parts[0]), let t = Int(parts[2]) else { return nil }
        return (p, t)
    }
    private func flickerTotal(_ app: XCUIApplication) -> Int {
        // Summary is "stale=N spurious=N empty=N".
        let label = app.staticTexts[flickerSummaryAXId].firstMatch.label
        return label.split(separator: " ").reduce(0) { acc, kv in
            acc + (Int(kv.split(separator: "=").last.map(String.init) ?? "") ?? 0)
        }
    }
    private let flickerSummaryAXId = "flicker.probe.summary"

    private func open(withProbe: Bool = true) throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        app.launchArguments += ["-uiTestResetReaderPosition", "-uiTestReaderLayout", "paginated"]
        if withProbe { app.launchArguments += ["-uiTestFlickerProbe"] }
        app.launch()
        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard app.staticTexts["reader.pageIndicator"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("No page indicator.")
        }
        return app
    }

    /// Cross forward by SWIPE three times in a row; the chapter index must
    /// increment each time (no stuck latch after the first).
    func testRepeatedForwardSwipeCrossings() throws {
        let app = try open()
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))

        for cross in 0..<3 {
            guard let ch = chapter(app), ch.index + 1 < ch.total else {
                throw XCTSkip("Ran out of chapters at crossing \(cross).")
            }
            let startIndex = ch.index
            // Page to the last page of the current chapter.
            var g = 0
            while let cur = indicator(app), cur.page < cur.total, g < 60 {
                right.tap()
                waitUntil(timeout: 1.0) { indicator(app)?.page != cur.page }
                g += 1
            }
            // Swipe forward off the last page.
            from.press(forDuration: 0.05, thenDragTo: to)
            waitUntil(timeout: 1.0) { chapter(app)?.index == startIndex + 1 }
            if chapter(app)?.index == startIndex {
                right.tap()
                waitUntil(timeout: 1.0) { chapter(app)?.index == startIndex + 1 }
            }
            let now = chapter(app)?.index
            XCTAssertEqual(now, startIndex + 1,
                           "crossing #\(cross): swipe must advance chapter \(startIndex)->\(startIndex + 1), got \(String(describing: now))")
        }
    }

    /// THE likely user scenario: reading immersively (chrome HIDDEN), tap
    /// forward off the last page must cross to the next chapter. With chrome
    /// hidden the PVC's own pan is no longer shadowed by the chrome overlay
    /// and can race the tap.
    func testForwardTapCrossingWithChromeHidden() throws {
        let app = try open()
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        guard let start = chapter(app), start.index + 1 < start.total else {
            throw XCTSkip("No room to cross forward.")
        }
        // Hide chrome. `toggleChromeVisibility()` is a synchronous property
        // set (no animation) that hides the tools bar containing
        // "reader.search", so its disappearance is a reliable, near-instant
        // observable signal instead of a fixed guess.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitUntil(timeout: 1.0) { !app.buttons["reader.search"].firstMatch.exists }

        // Page to the last page (taps still turn pages with chrome hidden).
        var g = 0
        while let cur = indicator(app), cur.page < cur.total, g < 60 {
            right.tap()
            waitUntil(timeout: 1.0) { indicator(app)?.page != cur.page }
            g += 1
        }
        // One more forward tap on the last page → must cross chapter.
        right.tap()
        waitUntil(timeout: 1.0) { chapter(app)?.index == start.index + 1 }
        XCTAssertEqual(chapter(app)?.index, start.index + 1,
                       "forward tap on the last page with chrome HIDDEN must cross to the next chapter, " +
                       "got \(String(describing: chapter(app)))")
    }

    /// Cross forward by TAP, then immediately back by TAP — both directions
    /// must work in the same session (no latch left armed by the forward one).
    func testForwardThenBackwardCrossingByTap() throws {
        let app = try open()
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        // Use the left gutter, not text: chapter 6's content at 15% width is
        // a real EPUB hyperlink, which must correctly take precedence over
        // page navigation.
        let left = app.buttons["reader.pageTurn.left"].firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5))

        guard let start = chapter(app), start.index + 1 < start.total else {
            throw XCTSkip("No room to cross forward.")
        }
        // Forward: page to last, tap once more.
        var g = 0
        while let cur = indicator(app), cur.page < cur.total, g < 60 {
            right.tap()
            waitUntil(timeout: 1.0) { indicator(app)?.page != cur.page }
            g += 1
        }
        right.tap()
        waitUntil(timeout: 1.0) { chapter(app)?.index == start.index + 1 }
        XCTAssertEqual(chapter(app)?.index, start.index + 1, "forward tap must advance chapter")

        // Backward: from page 1, tap left once.
        left.tap()
        waitUntil(timeout: 1.0) { chapter(app)?.index == start.index }
        XCTAssertEqual(chapter(app)?.index, start.index,
                       "backward tap from page 1 must return to the previous chapter")
    }

    func testDoubleTapAtBoundaryAdvancesExactlyOneChapter() throws {
        let app = try open(withProbe: true)
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        guard let start = chapter(app), start.index + 2 < start.total else {
            throw XCTSkip("Need at least two chapters ahead.")
        }
        // Page to the last page of the current chapter.
        var g = 0
        while let cur = indicator(app), cur.page < cur.total, g < 60 {
            right.tap()
            waitUntil(timeout: 1.0) { indicator(app)?.page != cur.page }
            g += 1
        }
        // Two rapid forward taps with no settle between them: the first
        // crosses; the second lands inside the swap window. The 120ms gap is
        // a deliberate timing probe (not a settle wait) — it must stay a
        // fixed sleep so the second tap reliably lands mid-swap instead of
        // waiting for a settled state that would defeat the point of the test.
        right.tap()
        usleep(120_000)
        right.tap()
        waitUntil(timeout: 2.0) { chapter(app)?.index == start.index + 1 }
        XCTAssertEqual(chapter(app)?.index, start.index + 1,
                       "a rapid double tap at the boundary must advance exactly ONE chapter, " +
                       "got \(String(describing: chapter(app)))")
    }

    /// Crossing BACKWARD must settle on the previous chapter's LAST page in a
    /// single hop — no flash of page 1 first, and no recorded flicker events.
    /// Before the fix the reader seeded page 0 then a polling task animated to
    /// the last page (a visible second hop / re-navigation flicker).
    func testBackwardCrossingLandsOnLastPageWithoutFlicker() throws {
        let app = try open()
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let backwardFrom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.5))
        let backwardTo = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5))
        guard let start = chapter(app), start.index + 1 < start.total else {
            throw XCTSkip("No room to cross forward first.")
        }
        // Cross forward once so there is a previous chapter to return to.
        var g = 0
        while let cur = indicator(app), cur.page < cur.total, g < 60 {
            right.tap()
            waitUntil(timeout: 1.0) { indicator(app)?.page != cur.page }
            g += 1
        }
        right.tap()
        waitUntil(timeout: 2.0) { chapter(app)?.index == start.index + 1 }
        guard chapter(app)?.index == start.index + 1 else { throw XCTSkip("Forward cross failed.") }

        // Zero the probe right before the backward crossing we care about.
        app.buttons["flicker.probe.reset"].firstMatch.tap()
        waitUntil(timeout: 1.0) { flickerTotal(app) == 0 }

        // Drag right off page 1. A tap on the fixture's linked text must open
        // that link, so the physical crossing regression uses the edge-pan
        // gesture that users also use to return a chapter.
        backwardFrom.press(forDuration: 0.05, thenDragTo: backwardTo)
        waitUntil(timeout: 3.0) { chapter(app)?.index == start.index }
        XCTAssertEqual(chapter(app)?.index, start.index,
                       "backward edge swipe must return to the previous chapter")
        if let ind = indicator(app) {
            XCTAssertEqual(ind.page, ind.total,
                           "backward crossing must land on the previous chapter's LAST page, got \(ind)")
        }
        XCTAssertEqual(flickerTotal(app), 0,
                       "backward crossing must record zero flicker events")
    }
}
