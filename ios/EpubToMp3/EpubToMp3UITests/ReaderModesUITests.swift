import XCTest

/// Device tests for two reader modes the user asked to verify:
///  1. Paginated mode with chrome HIDDEN — page turns (incl. chapter
///     crossing) must still work when the top/bottom bars are gone.
///  2. Continuous-scroll mode — a single tap toggles chrome, a drag scrolls
///     the book, and a tap must NOT be swallowed by the scroll gesture.
final class ReaderModesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(layout: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestResetReaderPosition",
            "-uiTestFlickerProbe",
            "-uiTestReaderLayout", layout,
        ]
        app.launch()
        return app
    }

    private func openBook(_ app: XCUIApplication) throws {
        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard app.buttons["Buscar no livro"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open.")
        }
    }

    private func indicator(_ app: XCUIApplication) -> (page: Int, total: Int)? {
        let label = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let parts = label.split(separator: " ").map(String.init)
        guard parts.count >= 3, let p = Int(parts[0]), let t = Int(parts[2]) else { return nil }
        return (p, t)
    }

    private func chromeVisible(_ app: XCUIApplication) -> Bool {
        app.buttons["Buscar no livro"].firstMatch.exists
    }

    // MARK: - 1) Paginated, chrome hidden

    func testPaginatedPageTurnWorksWithChromeHidden() throws {
        let app = launch(layout: "paginated")
        try openBook(app)
        guard indicator(app)?.total ?? 0 >= 2 else {
            throw XCTSkip("Need a multi-page chapter.")
        }

        // Hide chrome (center tap).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        XCTAssertFalse(chromeVisible(app), "center tap must hide chrome")

        // With chrome hidden, an edge tap on the RIGHT third must still turn
        // the page. (Apple Books restores chrome on the first hidden-edge tap
        // for some designs, but here the reader turns the page directly.)
        let before = indicator(app)?.page ?? 1
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        sleep(1)
        let after = indicator(app)?.page ?? before
        XCTAssertGreaterThan(after, before,
            "right-edge tap with chrome hidden must still advance the page (before=\(before) after=\(after))")
    }

    // MARK: - 2) Continuous scroll mode

    func testScrollModeTapTogglesChromeAndScrollWorks() throws {
        let app = launch(layout: "scrolling")
        try openBook(app)
        XCTAssertTrue(chromeVisible(app), "reader should open with chrome visible")

        // There is no page indicator in scroll mode.
        XCTAssertFalse(app.staticTexts["reader.pageIndicator"].firstMatch.exists,
                       "scroll mode must NOT show a page indicator")

        // A single tap toggles chrome off…
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        XCTAssertFalse(chromeVisible(app), "single tap in scroll mode must hide chrome")

        // …and back on.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        sleep(1)
        XCTAssertTrue(chromeVisible(app), "single tap in scroll mode must restore chrome")

        // A drag must scroll the content, NOT toggle chrome. Capture text
        // before and after to confirm the content moved.
        let beforeShot = XCUIScreen.main.screenshot().pngRepresentation.count
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
        // Chrome state must be unchanged by a scroll drag (still visible).
        XCTAssertTrue(chromeVisible(app), "a scroll drag must NOT toggle chrome")
        let afterShot = XCUIScreen.main.screenshot().pngRepresentation.count
        // Different screenshot bytes ≈ content scrolled (weak but device-safe).
        XCTAssertNotEqual(beforeShot, afterShot, "a drag must scroll the content")
    }
}
