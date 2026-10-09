import XCTest

@MainActor
final class RealBookReaderUITests: XCTestCase {
    func testActualLOTRReaderPaginationAndChrome() throws {
        try verifyReader(bookID: "3e1c676b270dfa3fe555eba4d0cb9934")
    }

    func testActualChristieReaderPaginationAndChrome() throws {
        try verifyReader(bookID: "55417053355de78768a0823d3cd203fd")
    }

    private func verifyReader(bookID: String) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        // Actual imported EPUBs only: never replace content or audio with UI fixtures.
        app.launchArguments = ["-developmentSeedBook", "-uiTestResetReaderPosition",
            "-uiTestReaderLayout", "paginated", "-uiTestChromeToggle",
            "-uiTestPaginationProbe", "-uiTestNoPageTurnOverlay"]
        app.launch()
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "The hash-verified real book must be imported.")
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let harness = ReaderModesHarness(app: app)
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].waitForNonExistence(timeout: 60),
                      "Reader navigation is intentionally blocked until loading finishes.")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let metrics = harness.paginationMetrics, (metrics.values["first"] ?? -1) >= 0,
               (metrics.values["total"] ?? 0) > 1 { break }
            usleep(100_000)
        }
        let initial = try XCTUnwrap(harness.paginationMetrics)
        XCTAssertGreaterThan(initial.values["total"] ?? 0, 1)
        harness.assertNoClippedLines(scenario: "\(bookID) initial actual EPUB")
        try turnPage(in: app, harness: harness, forward: true)
        harness.assertNoClippedLines(scenario: "\(bookID) next page")
        let advanced = try XCTUnwrap(harness.paginationMetrics)
        for _ in 0..<2 {
            harness.toggleChromeAndSettle(visible: false)
            harness.assertNoClippedLines(scenario: "\(bookID) hidden chrome")
            harness.toggleChromeAndSettle(visible: true)
            let restored = try XCTUnwrap(harness.paginationMetrics)
            XCTAssertEqual(restored.values["offset"], advanced.values["offset"])
            XCTAssertEqual(restored.values["first"], advanced.values["first"])
            harness.assertNoClippedLines(scenario: "\(bookID) restored chrome")
        }
        try turnPage(in: app, harness: harness, forward: false)
        harness.assertNoClippedLines(scenario: "\(bookID) previous page")
        let attachment = XCTAttachment(string: "bookID=\(bookID); initial=\(initial.values); advanced=\(advanced.values)")
        attachment.name = "actual-book-pagination-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func turnPage(in app: XCUIApplication, harness: ReaderModesHarness, forward: Bool) throws {
        let previous = try XCTUnwrap(harness.paginationMetrics?.values["page"])
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.exists)
        // Exercise production swipe handling, not test-only invisible overlay buttons.
        let visible = viewport.frame.intersection(app.windows.firstMatch.frame)
        XCTAssertGreaterThan(visible.height, 100)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: visible.minX + visible.width * (forward ? 0.75 : 0.25),
                                              dy: visible.minY + min(visible.height, 400) * 0.5))
        let end = origin.withOffset(CGVector(dx: visible.minX + visible.width * (forward ? 0.25 : 0.75),
                                            dy: visible.minY + min(visible.height, 400) * 0.5))
        let geometry = XCTAttachment(string: "viewport=\(viewport.frame); window=\(app.windows.firstMatch.frame); visible=\(visible)")
        geometry.name = "actual-swipe-screen-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        start.press(forDuration: 0, thenDragTo: end)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let current = harness.paginationMetrics?.values["page"], current != previous {
                XCTAssertEqual(current, previous + (forward ? 1 : -1))
                return
            }
            usleep(100_000)
        }
        XCTFail("An actual horizontal swipe must change the canonical page; metrics=\(harness.paginationMetrics?.values ?? [:])")
    }
}
