import XCTest

/// Captures a rapid screenshot burst DURING a single in-chapter page turn
/// (forward and backward), to catch a flash where page 1 (the first page)
/// briefly interleaves mid-animation. Paginated mode, chrome left visible so
/// the page indicator is readable per frame.
@MainActor
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
        app.launchArguments += ["-uiTestFixture"]
        app.launchArguments += [
            "-uiTestResetReaderPosition",
            "-uiTestReaderLayout", "paginated",
        ]
        app.launch()
        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard indicator(app) != nil else { throw XCTSkip("No page indicator.") }
        // The opening chapter (front matter) may be short. Page forward across
        // chapters until we land in one with >=3 pages.
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        var guardCount = 0
        while (indicator(app)?.total ?? 0) < 3, guardCount < 30 {
            let prevTotal = indicator(app)?.total ?? 0
            right.tap()
            waitUntil(timeout: 1.0) { (indicator(app)?.total ?? prevTotal) != prevTotal }
            guardCount += 1
        }
        // Need >=3 pages so we can turn in the MIDDLE (page 1 -> 2), never at
        // a boundary (a boundary turn legitimately resets currentPage to 0 for
        // the next chapter, which is not the flash we're hunting).
        guard (indicator(app)?.total ?? 0) >= 3 else {
            throw XCTSkip("Could not reach a chapter with >=3 pages.")
        }
        // Make sure we're on page 1 of that chapter for a deterministic start.
        let left = app.buttons["reader.pageTurn.left"].firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        guardCount = 0
        while (indicator(app)?.page ?? 1) > 1, guardCount < 20 {
            let prevPage = indicator(app)?.page ?? 1
            left.tap()
            waitUntil(timeout: 1.0) { (indicator(app)?.page ?? prevPage) != prevPage }
            guardCount += 1
        }
        return app
    }

    func testForwardThenBackwardTurnBurst() throws {
        let app = try open()
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        let left = app.buttons["reader.pageTurn.left"].firstMatch

        // Advance to page 2 first so a backward turn has somewhere to go and a
        // forward turn is mid-chapter (page 1 should NEVER reappear).
        right.tap()
        waitUntil(timeout: 1.5) { indicator(app)?.page == 2 }
        XCTAssertEqual(indicator(app)?.page, 2, "should be on page 2 before the burst")

        // Forward turn burst capture (page 2 -> 3).
        right.tap()
        var pagesSeen: Set<Int> = []
        for i in 0..<10 {
            attach(app, "fwd-\(i < 10 ? "0" : "")\(i)")
            if let p = indicator(app)?.page { pagesSeen.insert(p) }
            usleep(60_000)
        }
        attach(app, "fwd-settled")
        // During a forward turn from page 2, page 1 must never flash.
        XCTAssertFalse(pagesSeen.contains(1),
                       "page 1 must not flash during a forward turn; saw pages \(pagesSeen.sorted())")

        waitUntil(timeout: 1.5) { indicator(app)?.page == 3 }
        // Backward turn burst capture.
        left.tap()
        var backSeen: Set<Int> = []
        for i in 0..<10 {
            attach(app, "back-\(i < 10 ? "0" : "")\(i)")
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
