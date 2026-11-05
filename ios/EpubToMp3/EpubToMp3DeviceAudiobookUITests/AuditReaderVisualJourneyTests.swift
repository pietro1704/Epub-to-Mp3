import XCTest

/// Opt-in verification of the installed reader; preserves books and models.
@MainActor
final class AuditReaderVisualJourneyTests: XCTestCase {
    func testJustifiedReaderAndWholeDeviceRotationCapture() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] == "com.pietrocode.epubtomp3" else {
            throw XCTSkip("Requires the installed physical app")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        app.launchArguments = ["-AppleLanguages", "(en)", "-uiTestResetActiveReader",
            "-player.presentation.expanded.v1", "NO", "-readerLayout", "paginated",
            "-readerOverrideTextAlignment", "YES", "-readerTextAlignment", "justified",
            "-readerMargin", "80", "-uiTestPaginationProbe"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        for identifier in ["fullPlayer.close", "reader.close", "mainReader.browseLibrary"] {
            let button = app.buttons[identifier].firstMatch
            if button.exists && button.isHittable { button.tap() }
        }
        let library = app.tabBars.buttons["Library"].firstMatch
        if !library.waitForExistence(timeout: 3) {
            let browse = app.buttons["mainReader.browseLibrary"].firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 10))
            browse.tap()
        }
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let book = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", "The Lord of the Rings")).firstMatch
        for _ in 0..<12 where !book.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(book.isHittable, "Install the standard Lord of the Rings acceptance book first")
        book.tap()
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 20))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(wait {
                let frame = app.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            })
            let probe = app.staticTexts["reader.paginationProbe"].firstMatch
            XCTAssertTrue(wait { probe.exists && probe.label.contains("clippedLineCount=0;") })
            let metrics = XCTAttachment(string: probe.label)
            metrics.name = "whole-device-\(orientation.rawValue)-reader-metrics"
            metrics.lifetime = .keepAlways
            add(metrics)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "whole-device-\(orientation.rawValue)-reader"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 10) == .completed
    }
}
