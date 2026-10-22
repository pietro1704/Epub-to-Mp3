import XCTest

extension ReaderModesUITests {
    func testNativeLOTRLandscapePaginationKeepsEveryGlyphVisible() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchNativeLOTR()
        try openBook(app, titleContaining: "lord")
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 30), "The native LOTR reader must open.")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(viewport.waitForExistence(timeout: 10), "The reader viewport must survive rotation.")
        XCTAssertTrue(
            waitUntil(timeout: 15) {
                let metrics = self.paginationMetrics(app)
                return (metrics["total"] ?? 0) > 0
                    && (metrics["viewportHeight"] ?? 0) > 0
                    && metrics["paginatedHeightActive"] == 1
            },
            "The native LOTR reader must finish landscape pagination before glyph validation."
        )
        assertNoClippedPageLines(app, scenario: "native LOTR landscape initial page")

        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.50)).tap()
        usleep(700_000)
        assertNoClippedPageLines(app, scenario: "native LOTR landscape advanced page")
    }

    func testRapidChromeTogglesAndPageTurnsNeverClipLines() throws {
        let app = launch(layout: "paginated")
        try openBook(app)

        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))

        for iteration in 0..<4 {
            right.tap()
            usleep(650_000)
            toggleReaderChrome(in: app)
            // This intentionally lands while the chrome animation is in
            // flight. A second tap and an edge turn used to apply stale page
            // offsets and leave a clipped line at a viewport edge.
            usleep(40_000)
            toggleReaderChrome(in: app)
            right.tap()
            usleep(700_000)
            assertNoClippedPageLines(app, scenario: "rapid chrome/page cycle \(iteration)")
        }
    }

    func testSmallNativeSerifFontSurvivesRapidChromeTogglesWithoutClippingOrLargeGap() throws {
        let app = launch(layout: "paginated", smallFont: true)
        try openBook(app)
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCTAssertTrue(right.waitForExistence(timeout: 5))

        for iteration in 0..<6 {
            right.tap()
            usleep(400_000)
            toggleReaderChrome(in: app)
            usleep(35_000)
            toggleReaderChrome(in: app)
            usleep(550_000)
            assertNoClippedPageLines(app, scenario: "small native-serif rapid chrome cycle \(iteration)")
            let metrics = paginationMetrics(app)
            let lastY = metrics["lastCompleteY"] ?? 0
            let viewportBottom = metrics["viewportBottom"] ?? 0
            XCTAssertLessThanOrEqual(
                viewportBottom - lastY,
                60,
                "small native-serif page must not acquire a large blank footer after chrome toggling (\(metrics))"
            )
        }
    }

    func testPaginatedPageTurnAppliesTheMeasuredTextHeight() throws {
        let app = launch(layout: "paginated")
        try openBook(app)

        let nextPage = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(nextPage.waitForExistence(timeout: 5), "The next-page target must be available.")
        nextPage.tap()
        sleep(1)

        let metrics = paginationMetrics(app)
        let measured = metrics["measuredTextHeight"] ?? 0
        let frame = metrics["textFrameHeight"] ?? 0
        let viewport = metrics["viewportHeight"] ?? 0
        let paginatedHeightActive = metrics["paginatedHeightActive"] ?? 0
        let scrollingHeightActive = metrics["scrollingHeightActive"] ?? 0
        XCTAssertGreaterThan(measured, viewport * 2, "The fixture must span multiple paginated viewports.")
        XCTAssertEqual(
            frame,
            measured,
            accuracy: 1,
            "A paginated page turn must lay out the text to its measured height instead of clipping it to one viewport (paginated active: \(paginatedHeightActive), scrolling active: \(scrollingHeightActive))."
        )
    }
}
