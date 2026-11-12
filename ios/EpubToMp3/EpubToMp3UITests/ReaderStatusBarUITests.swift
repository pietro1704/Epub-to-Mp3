import XCTest

@MainActor
final class ReaderStatusBarUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testPaginatedReaderKeepsStatusBarHiddenUntilReturningToLibrary() throws {
        try verifyStatusBarPreservesReaderSafeArea(layout: "paginated")
    }

    func testScrollingReaderKeepsStatusBarHiddenUntilReturningToLibrary() throws {
        try verifyStatusBarPreservesReaderSafeArea(layout: "scrolling")
    }

    private func verifyStatusBarPreservesReaderSafeArea(layout: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let application = XCUIApplication()
        // Exercise the staged native EPUB without replacing the user's library
        // or clearing saved progress. Layout overrides are launch-only values.
        application.launchArguments = [
            "-uiTestResetActiveReader", "-developmentSeedBook",
            "-uiTestReaderLayout", layout, "-uiTestPaginationProbe",
            "-uiTestReaderShowPageNumbers", "-uiTestNoPageTurnOverlay"
        ]
        let harness = ReaderModesHarness(app: application)
        app = application
        application.launch()
        assertStatusBar(visible: true, in: application, scenario: "library")
        XCTAssertTrue(application.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).matching(NSPredicate(format: "label CONTAINS[c] %@", "lord"))
            .firstMatch.waitForExistence(timeout: 20), "The staged LOTR EPUB must be available.")
        try harness.openBook(titleContaining: "lord")
        XCTAssertTrue(harness.chromeIsVisible)
        assertStatusBar(visible: false, in: application, scenario: "reader with chrome")

        let viewport = application.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        // Retain the user's current passage while exercising chrome changes.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let metrics = harness.paginationMetrics?.values else { return false }
            return (metrics["first"] ?? -1) >= 0 && (metrics["viewportHeight"] ?? 0) > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
        let originalFrame = viewport.frame
        let originalOffset = try XCTUnwrap(harness.paginationMetrics?.values["offset"])
        let originalAnchor = try XCTUnwrap(harness.paginationMetrics?.values["first"])

        for iteration in 0..<3 {
            // Use the actual reading surface, never the test-only chrome button.
            toggleChrome(harness, layout: layout, visible: false)
            assertStatusBar(visible: false, in: application, scenario: "immersive \(iteration)")
            let metrics = try XCTUnwrap(harness.paginationMetrics?.values)
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(metrics["viewportTop"]),
                                       try XCTUnwrap(metrics["safeTop"]))
            XCTAssertLessThanOrEqual(try XCTUnwrap(metrics["viewportBottom"]),
                                    try XCTUnwrap(metrics["safeBottom"]))
            if layout == "paginated" {
                harness.assertNoClippedLines(scenario: "immersive status bar \(iteration)")
            }
            toggleChrome(harness, layout: layout, visible: true)
            assertStatusBar(visible: false, in: application, scenario: "restored \(iteration)")
            XCTAssertEqual(viewport.frame, originalFrame)
            XCTAssertEqual(harness.paginationMetrics?.values["offset"], originalOffset)
            XCTAssertEqual(harness.paginationMetrics?.values["first"], originalAnchor)
            if layout == "paginated" {
                harness.assertNoClippedLines(scenario: "restored status bar \(iteration)")
            }
        }

        // A later show request must win when toggles arrive in quick succession.
        tapChrome(harness, layout: layout)
        tapChrome(harness, layout: layout)
        assertStatusBar(visible: false, in: application, scenario: "consecutive toggles")
        XCTAssertTrue(harness.chromeIsVisible)
        XCTAssertEqual(harness.paginationMetrics?.values["offset"], originalOffset)

        let close = application.buttons["reader.close"].firstMatch
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(application.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch.waitForExistence(timeout: 5))
        assertStatusBar(visible: true, in: application, scenario: "returned to library")
    }

    private func tapChrome(_ harness: ReaderModesHarness, layout: String) {
        if layout == "scrolling" {
            harness.app.scrollViews["reader.viewport"].firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            harness.toggleChrome()
        }
    }

    private func toggleChrome(_ harness: ReaderModesHarness, layout: String, visible: Bool) {
        tapChrome(harness, layout: layout)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            harness.chromeIsVisible == visible
                && harness.paginationMetrics?.values["chromeHidden"] == (visible ? 0 : 1)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "Reader chrome must settle to visible=\(visible): \(harness.paginationMetrics?.values ?? [:])")
    }

    private func assertStatusBar(visible: Bool, in app: XCUIApplication, scenario: String) {
        // Query the system accessibility element, not the app's requested state.
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Recent iOS versions expose the status bar through SpringBoard rather
        // than the foreground app. Query both owners without activating either.
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let bars = app.statusBars.allElementsBoundByIndex + system.statusBars.allElementsBoundByIndex
                return bars.contains { $0.exists && !$0.frame.isEmpty } == visible
            },
            object: nil
        )
        let result = XCTWaiter.wait(for: [settled], timeout: 5)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = scenario
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(result, .completed,
                       "\(scenario): system status bar visibility must be \(visible).")
    }
}
