import XCTest

/// Device tests for two reader modes the user asked to verify:
///  1. Paginated mode with chrome HIDDEN — page turns (incl. chapter
///     crossing) must still work when the top/bottom bars are gone.
///  2. Continuous-scroll mode — a single tap toggles chrome, a drag scrolls
///     the book, and a tap must NOT be swallowed by the scroll gesture.
@MainActor
final class ReaderModesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func launch(
        layout: String,
        smallFont: Bool = false,
        showsPageTurnOverlay: Bool = false,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        ReaderModesHarness().launch(.init(
            source: .fixture,
            layout: layout,
            smallFont: smallFont,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true,
            flickerProbeEnabled: true,
            showsPageTurnOverlay: showsPageTurnOverlay,
            additionalArguments: additionalArguments
        ))
    }

    func launchForLiveSettings() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestFixture",
            "-uiTestResetReaderPosition",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    func launchNativeLOTR() -> XCUIApplication {
        ReaderModesHarness().launch(.paginatedNativeLOTR)
    }

    func openBook(_ app: XCUIApplication, titleContaining title: String? = nil) throws {
        try ReaderModesHarness(app: app).openBook(titleContaining: title)
    }

    func indicator(_ app: XCUIApplication) -> (page: Int, total: Int)? {
        let element = app.staticTexts["reader.pageIndicator"].firstMatch
        guard element.waitForExistence(timeout: 2) else { return nil }
        let text = (element.value as? String) ?? element.label
        let values = text
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        guard let page = values.first, let total = values.last else { return nil }
        return (page, total)
    }

    func chromeVisible(_ app: XCUIApplication) -> Bool {
        ReaderModesHarness(app: app).chromeIsVisible
    }

    func toggleReaderChrome(in app: XCUIApplication) {
        ReaderModesHarness(app: app).toggleChrome()
    }

    func chapter(_ app: XCUIApplication) -> (index: Int, total: Int)? {
        let element = app.staticTexts["flicker.probe.chapter"].firstMatch
        guard element.waitForExistence(timeout: 2) else { return nil }
        let label = element.label
        let parts = label.split(separator: "/").map(String.init)
        guard parts.count == 2, let index = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (index, total)
    }

    func paginationMetrics(_ app: XCUIApplication) -> [String: Int] {
        ReaderModesHarness(app: app).paginationMetrics?.values ?? [:]
    }

    func assertNoClippedPageLines(
        _ app: XCUIApplication,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        ReaderModesHarness(app: app).assertNoClippedLines(scenario: scenario, file: file, line: line)
    }

    func openReaderSettings(_ app: XCUIApplication) throws {
        let settings = app.buttons["reader.settings.toggle"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Reader settings button must be available.")
        settings.tap()
        XCTAssertTrue(
            app.cells["reader.settings.mode"].firstMatch.waitForExistence(timeout: 5),
            "The settings sheet must expose its reader-mode control through a stable identifier."
        )
    }

    func chooseLayout(_ name: String, in app: XCUIApplication) throws {
        let mode = app.cells["reader.settings.mode"].firstMatch
        XCTAssertTrue(mode.exists, "Reader mode control must remain visible while the sheet is open.")
        if (mode.value as? String) == name { return }
        mode.tap()
        let choice = app.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "The \(name) mode option must be selectable.")
        choice.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "The settings sheet must remain open after changing the reader mode.")
    }

    func waitForExistence(
        _ element: XCUIElement,
        equals expected: Bool,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists == expected
    }



    func dragReaderSlider(_ slider: XCUIElement, to fraction: CGFloat) {
        let inset = 9 / slider.frame.width
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: slider.coordinate(
                withNormalizedOffset: CGVector(dx: inset + fraction * (1 - 2 * inset), dy: 0.5)
            ))
    }

    // MARK: - 1) Paginated, chrome hidden


    // MARK: - 1b) Paginated chrome toggle (single-page safe)













    // MARK: - 2) Continuous scroll mode



}
