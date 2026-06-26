import XCTest

/// Captures a rapid screenshot burst DURING a single in-chapter page turn
/// (forward and backward), to catch a flash where page 1 (the first page)
/// briefly interleaves mid-animation. Paginated mode, chrome left visible so
/// the page indicator is readable per frame.
final class PageTurnFlashUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func indicator(_ app: XCUIApplication) -> (page: Int, total: Int)? {
        let label = app.staticTexts["reader.pageIndicator"].firstMatch.label
        let parts = label.split(separator: " ").map(String.init)
        guard parts.count >= 3, let p = Int(parts[0]), let t = Int(parts[2]) else { return nil }
        return (p, t)
    }

    private func open() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestResetReaderPosition",
            "-uiTestFlickerProbe",
            "-uiTestDisableEdgePan",
            "-uiTestReaderLayout", "paginated",
        ]
        app.launch()
        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard indicator(app) != nil else { throw XCTSkip("No page indicator.") }
        // The opening chapter (front matter) may be short. Page forward across
        // chapters until we land in one with >=3 pages.
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        var guardCount = 0
        while (indicator(app)?.total ?? 0) < 3, guardCount < 30 {
            right.tap(); usleep(700_000); guardCount += 1
        }
        // Need >=3 pages so we can turn in the MIDDLE (page 1 -> 2), never at
        // a boundary (a boundary turn legitimately resets currentPage to 0 for
        // the next chapter, which is not the flash we're hunting).
        guard (indicator(app)?.total ?? 0) >= 3 else {
            throw XCTSkip("Could not reach a chapter with >=3 pages.")
        }
        // Make sure we're on page 1 of that chapter for a deterministic start.
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        guardCount = 0
        while (indicator(app)?.page ?? 1) > 1, guardCount < 20 {
            left.tap(); usleep(700_000); guardCount += 1
        }
        return app
    }

    func testForwardThenBackwardTurnBurst() throws {
        let app = try open()
        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))

        // Advance to page 2 first so a backward turn has somewhere to go and a
        // forward turn is mid-chapter (page 1 should NEVER reappear).
        right.tap(); usleep(900_000)
        XCTAssertEqual(indicator(app)?.page, 2, "should be on page 2 before the burst")

        // Forward turn burst capture (page 2 -> 3).
        right.tap()
        var pagesSeen: Set<Int> = []
        for i in 0..<10 {
            attach(app, String(format: "fwd-%02d", i))
            if let p = indicator(app)?.page { pagesSeen.insert(p) }
            usleep(60_000)
        }
        attach(app, "fwd-settled")
        let log = app.staticTexts["flicker.probe.lastlog"].firstMatch.label
        // During a forward turn from page 3, page 1 must never flash.
        XCTAssertFalse(pagesSeen.contains(1),
                       "page 1 must not flash during a forward turn; saw pages \(pagesSeen.sorted()) log=[\(log)]")

        usleep(800_000)
        // Backward turn burst capture.
        left.tap()
        var backSeen: Set<Int> = []
        for i in 0..<10 {
            attach(app, String(format: "back-%02d", i))
            if let p = indicator(app)?.page { backSeen.insert(p) }
            usleep(60_000)
        }
        attach(app, "back-settled")
        XCTAssertFalse(backSeen.contains(1),
                       "page 1 must not flash during a backward turn; saw pages \(backSeen.sorted())")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
