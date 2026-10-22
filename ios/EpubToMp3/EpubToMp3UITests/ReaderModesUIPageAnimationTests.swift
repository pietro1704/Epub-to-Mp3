import XCTest

extension ReaderModesUITests {
    func testAnimatedForwardAndBackwardTurnsRestoreThePage() throws {
        let app = launch(
            layout: "paginated",
            showsPageTurnOverlay: true,
            additionalArguments: ["-uiTestPageTurnStyle", "flip"]
        )
        try openBook(app)
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        let left = app.buttons["reader.pageTurn.left"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        XCTAssertTrue(left.waitForExistence(timeout: 5))

        let before = try XCTUnwrap(indicator(app)?.page)
        // XCTest waits for animation idleness after tap. The direct native
        // animation test inspects the transient fold while it is still active.
        right.tap()
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.indicator(app)?.page == before + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        XCTAssertEqual(paginationMetrics(app)["clippedLineCount"], 0)
        left.tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.indicator(app)?.page == before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertEqual(paginationMetrics(app)["clippedLineCount"], 0)
        XCTAssertFalse(app.otherElements["reader.pageCurl"].firstMatch.exists)
    }

    func testReduceMotionSkipsThePageCurl() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestFixture", "-uiTestResetReaderPosition",
            "-uiTestReaderLayout", "paginated",
            "-uiTestPageTurnStyle", "flip",
            "-uiTestReduceMotion",
        ]
        app.launch()
        try openBook(app)
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        right.tap()
        XCTAssertFalse(
            app.otherElements["reader.pageCurl"].firstMatch.waitForExistence(timeout: 0.5),
            "Reduce Motion must change the page without a curl overlay."
        )
    }
}
