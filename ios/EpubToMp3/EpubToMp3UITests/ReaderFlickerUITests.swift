import XCTest

/// Device-only regression suite that proves the paginated reader does NOT
/// flicker during page turns, chapter switches, and chrome toggles.
///
/// Screenshots cannot catch a 1-frame text-snap reliably, so instead the app
/// is launched with `-uiTestFlickerProbe`, which arms `FlickerProbe`. The
/// probe counts the three transient glitches the user reported:
///
///   stale=N    — visible page re-pushed a different slice with no gesture
///   spurious=N — programmatic re-navigation fought an in-flight turn
///   empty=N    — body fell back to stale/empty pages mid chapter-switch
///
/// A hidden accessibility element (`flicker.probe.summary`) surfaces the live
/// counters; `flicker.probe.reset` zeroes them between scenarios. Each test
/// scripts an interaction, then asserts every counter is 0.
final class ReaderFlickerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchInReader() throws -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFlickerProbe"]
        app.launch()

        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else {
            throw XCTSkip("No book in library; skipping flicker test.")
        }
        firstBook.tap()

        // Reader chrome present == we're inside the book.
        let searchButton = app.buttons["Buscar no livro"].firstMatch
        guard searchButton.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open; skipping flicker test.")
        }
        return app
    }

    private func probeSummary(_ app: XCUIApplication) -> String {
        app.staticTexts["flicker.probe.summary"].firstMatch.label
    }

    @discardableResult
    private func resetProbe(_ app: XCUIApplication) -> Bool {
        // Let the initial chapter fully paginate before zeroing counters, so
        // the one-time cold-load (empty pages until the first pagination
        // lands) isn't attributed to the scripted interaction that follows.
        usleep(1_500_000)
        let reset = app.buttons["flicker.probe.reset"].firstMatch
        guard reset.waitForExistence(timeout: 5) else { return false }
        reset.tap()
        // Confirm the reset actually landed — the summary must read all-zero
        // before the scripted interaction begins, otherwise a stale cold-load
        // counter would masquerade as interaction-induced flicker.
        usleep(300_000)
        return totalEvents(probeSummary(app)) == 0
    }

    /// Total events parsed from "stale=0 spurious=0 empty=0".
    private func totalEvents(_ summary: String) -> Int {
        summary
            .split(separator: " ")
            .compactMap { token -> Int? in
                guard let eq = token.firstIndex(of: "=") else { return nil }
                return Int(token[token.index(after: eq)...])
            }
            .reduce(0, +)
    }

    private func assertNoFlicker(
        _ app: XCUIApplication,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let summary = probeSummary(app)
        XCTAssertFalse(summary.isEmpty,
                       "Flicker probe overlay missing — is the app armed?",
                       file: file, line: line)
        XCTAssertEqual(totalEvents(summary), 0,
                       "\(scenario): expected no flicker events, got [\(summary)]",
                       file: file, line: line)
    }

    // MARK: - Page turns (curl/flip)

    /// Burst of forward/back taps must produce zero stale-slice and zero
    /// spurious-renavigation events. This is the core curl-flicker test.
    func testPageTurnBurstDoesNotFlicker() throws {
        let app = try launchInReader()
        let indicator = app.staticTexts["reader.pageIndicator"].firstMatch
        guard indicator.waitForExistence(timeout: 15) else {
            throw XCTSkip("No page indicator (single-page chapter).")
        }
        XCTAssertTrue(resetProbe(app), "probe must reset to all-zero before the interaction")

        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))

        // Several forward turns, then several back — paced just above the
        // 0.5s debounce so each one actually lands (a too-fast burst is
        // swallowed by the debounce and wouldn't exercise the turn path).
        for _ in 0..<5 { right.tap(); usleep(700_000) }
        for _ in 0..<5 { left.tap(); usleep(700_000) }

        assertNoFlicker(app, scenario: "page-turn burst")
    }

    // MARK: - Chapter switch

    /// Paging forward off the last page of a chapter (and back) must not
    /// flash stale/empty pages. Drives many forward taps to cross at least
    /// one chapter boundary, then reverses.
    func testChapterCrossingDoesNotFlicker() throws {
        let app = try launchInReader()
        guard app.staticTexts["reader.pageIndicator"].firstMatch.waitForExistence(timeout: 15) else {
            throw XCTSkip("No page indicator (single-page chapter).")
        }
        XCTAssertTrue(resetProbe(app), "probe must reset to all-zero before the interaction")

        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        // Enough taps to page through a short chapter and cross the boundary.
        for _ in 0..<25 { right.tap(); usleep(650_000) }

        assertNoFlicker(app, scenario: "chapter crossing")
    }

    // MARK: - Chrome / settings

    /// Toggling chrome (center tap) repeatedly must not re-push slices or
    /// re-navigate — the layout is a true overlay and text must stay put.
    func testChromeToggleDoesNotFlicker() throws {
        let app = try launchInReader()
        guard app.staticTexts["reader.pageIndicator"].firstMatch.waitForExistence(timeout: 15) else {
            throw XCTSkip("No page indicator (single-page chapter).")
        }
        XCTAssertTrue(resetProbe(app), "probe must reset to all-zero before the interaction")

        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<6 { center.tap(); usleep(500_000) }

        assertNoFlicker(app, scenario: "chrome toggle")
    }

    // MARK: - Concurrent re-render (auto-follow / reflow window)

    /// Interleaving page turns with chrome toggles forces the reader to
    /// re-render the body (a fresh `pages` capture) WHILE a page-change closure
    /// may still be running. That is the exact window in which a closure that
    /// read the raw captured `pages` saw an empty array and snapped to page 0 —
    /// the flicker seen on audio auto-follow, which now routes every lookup
    /// through `livePages(fallback:)`. Zero events proves no closure collapsed
    /// to page 0 during the concurrent re-render.
    func testPageTurnDuringChromeToggleDoesNotFlicker() throws {
        let app = try launchInReader()
        guard app.staticTexts["reader.pageIndicator"].firstMatch.waitForExistence(timeout: 15) else {
            throw XCTSkip("No page indicator (single-page chapter).")
        }
        XCTAssertTrue(resetProbe(app), "probe must reset to all-zero before the interaction")

        let right = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // Turn, toggle chrome (forces a body re-render), turn again — repeated
        // so a page-change closure overlaps the re-render window.
        for i in 0..<6 {
            (i.isMultiple(of: 2) ? right : left).tap()
            usleep(200_000)
            center.tap()
            usleep(600_000)
        }

        assertNoFlicker(app, scenario: "page turn during chrome toggle")
    }
}
