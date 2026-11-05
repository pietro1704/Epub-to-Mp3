import XCTest

extension ReaderModesUITests {
    func testNativeLOTRAudioTrackingChoicePersistsWithoutMovingTheReader() throws {
        let harness = ReaderModesHarness()
        let app = harness.launch(.init(source: .seededLOTR, layout: "paginated", smallFont: false,
            chromeToggleEnabled: true, paginationProbeEnabled: true,
            additionalArguments: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]))
        defer { app.terminate() }
        try harness.openBook(titleContaining: "lord", timeout: 30)
        XCTAssertTrue(app.staticTexts["reader.paginationProbe"].firstMatch.waitForExistence(timeout: 30))
        harness.assertNoClippedLines(scenario: "before tracking preference")
        let baseline = harness.paginationMetrics?.values["offset"]
        try openReaderSettings(app)
        let toggle = app.switches["reader.settings.audioTracking"].firstMatch
        for _ in 0..<10 where !toggle.isHittable { app.tables.firstMatch.swipeUp() }
        XCTAssertTrue(toggle.isHittable)
        let initial = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, initial)
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(harness.paginationMetrics?.values["offset"], baseline)
        harness.assertNoClippedLines(scenario: "tracking preference disabled")
        try openReaderSettings(app)
        for _ in 0..<10 where !toggle.isHittable { app.tables.firstMatch.swipeUp() }
        XCTAssertNotEqual(toggle.value as? String, initial, "Aa must retain the explicit preference")
        toggle.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(harness.paginationMetrics?.values["offset"], baseline)
        harness.assertNoClippedLines(scenario: "tracking preference restored")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "native-lotr-tracking-round-trip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
