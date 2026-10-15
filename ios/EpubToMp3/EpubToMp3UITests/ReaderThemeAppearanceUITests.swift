import XCTest

/// Real seeded EPUB evidence; runtime colour assertions live in ReaderThemeAppearanceTests.
@MainActor
final class ReaderThemeAppearanceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSeededBookDarkThemeUnderLightSystemAndLiveThemeSelection() throws {
        try verify(theme: "dark", systemStyle: "Light", nextTheme: "Light")
    }

    func testSeededBookLightThemeUnderDarkSystemAndLiveThemeSelection() throws {
        try verify(theme: "light", systemStyle: "Dark", nextTheme: "Dark")
    }

    private func verify(theme: String, systemStyle: String, nextTheme: String) throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Do not use uiTestResetReaderPosition: preserve this book's existing progress.
        app.launchArguments = ["-developmentSeedBook", "-uiTestResetActiveReader", "-uiTestPlaybackFixture", "-uiTestChromeToggle",
            "-uiTestPaginationProbe", "-uiTestNoPageTurnOverlay", "-uiTestReaderLayout", "paginated",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", systemStyle,
            "-readerTheme", theme]
        app.launch()
        defer { app.terminate() }
        let harness = ReaderModesHarness(app: app)
        if !app.buttons["reader.settings.toggle"].firstMatch.waitForExistence(timeout: 3) {
            try harness.openBook(titleContaining: "Lord", timeout: 60)
        }
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        harness.toggleChromeAndSettle(visible: true, timeout: 10)
        let before = try waitForMetrics(harness, app: app)
        harness.assertNoClippedLines(scenario: "\(theme) theme under \(systemStyle) system")
        attach(app, name: "seeded-lotr-\(theme)-system-\(systemStyle)")

        app.buttons["reader.settings.toggle"].firstMatch.tap()
        let choice = app.cells.matching(NSPredicate(format: "label == %@", nextTheme)).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "The live reader theme must be selectable.")
        if !choice.isHittable { app.tables.firstMatch.swipeUp() }
        XCTAssertTrue(choice.isHittable)
        choice.tap()
        XCTAssertTrue(waitUntil { (choice.value as? String)?.contains("selected") == true })
        attach(app, name: "seeded-lotr-live-\(nextTheme)-settings")

        // Dismiss the native sheet without closing or recreating the reader.
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "The native reader settings sheet must expose Done.")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Done must leave the accessibility tree after the sheet is dismissed.")
        let after = try waitForMetrics(harness, app: app)
        for key in ["offset", "first", "total", "viewportTop", "viewportBottom"] {
            XCTAssertNotNil(before[key], "The \(key) geometry probe is required.")
            XCTAssertEqual(after[key], before[key], "A colour-only choice must preserve \(key).")
        }
        harness.assertNoClippedLines(scenario: "Live switch to \(nextTheme)")
        attach(app, name: "seeded-lotr-live-\(nextTheme)-page")
    }

    private func waitForMetrics(_ harness: ReaderModesHarness, app: XCUIApplication) throws -> [String: Int] {
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 15))
        var previous: [String: Int]?
        var stableSince = Date()
        XCTAssertTrue(waitUntil(timeout: 15) {
            guard let metrics = harness.paginationMetrics else { return false }
            let values = metrics.values
            guard (metrics.total ?? 0) > 0, (values["first"] ?? -1) >= 0,
                  let top = values["viewportTop"], let bottom = values["viewportBottom"] else { return false }
            let frame = viewport.frame
            // A sheet animates the presenting view. Require its probe to describe
            // the actual visible scroll surface before comparing final geometry.
            guard abs(CGFloat(top) - frame.minY) <= 1,
                  abs(CGFloat(bottom) - frame.maxY) <= 1 else {
                previous = nil
                stableSince = Date()
                return false
            }
            if values != previous {
                previous = values
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.4
        }, "The final pagination probe must settle and match the visible reader viewport; probe=\(harness.paginationMetrics?.values ?? [:]); viewport=\(viewport.frame).")
        return try XCTUnwrap(harness.paginationMetrics?.values)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
