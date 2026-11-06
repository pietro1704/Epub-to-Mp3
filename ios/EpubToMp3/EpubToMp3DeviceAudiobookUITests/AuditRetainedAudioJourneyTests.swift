import XCTest

@MainActor
final class AuditRetainedAudioJourneyTests: XCTestCase {
    func testInstalledPortugueseChapterPreservesFullDurationAndPausedTransport() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] == "com.pietrocode.epubtomp3" else {
            throw XCTSkip("Requires the installed physical app and Portuguese acceptance book")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        app.launchArguments = ["-AppleLanguages", "(en)", "-uiTestResetActiveReader",
            "-player.presentation.expanded.v1", "NO"]
        app.launch()
        defer { app.terminate() }
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
        let book = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "Piper Live Portuguese")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        for _ in 0..<8 where !book.isHittable { app.collectionViews.firstMatch.swipeUp() }
        book.tap()
        XCTAssertTrue(wait(15) { app.buttons.matching(identifier: "miniPlayer.playPause")
            .allElementsBoundByIndex.contains(where: \.isHittable) })
        let miniPlay = try XCTUnwrap(app.buttons.matching(identifier: "miniPlayer.playPause")
            .allElementsBoundByIndex.first(where: \.isHittable))
        let readerCapture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        readerCapture.name = "portuguese-reader-before-playback"
        readerCapture.lifetime = .keepAlways
        add(readerCapture)
        if miniPlay.label == "Play" { miniPlay.tap() }
        try XCTUnwrap(app.buttons.matching(identifier: "miniPlayer.open")
            .allElementsBoundByIndex.first(where: \.isHittable)).tap()
        let play = app.buttons["fullPlayer.playPause"].firstMatch
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let remaining = app.staticTexts["fullPlayer.remaining"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(60) { self.seconds(elapsed.label) >= 2 && self.seconds(remaining.label) > 30 })
        if play.label == "Pause" { play.tap() }
        XCTAssertTrue(wait(5) { play.label == "Play" })
        let before = seconds(elapsed.label)
        app.buttons["fullPlayer.skipForward"].firstMatch.tap()
        XCTAssertTrue(wait(10) { abs(self.seconds(elapsed.label) - before - 15) <= 2 })
        XCTAssertEqual(play.label, "Play")
        app.buttons["fullPlayer.skipBack"].firstMatch.tap()
        XCTAssertTrue(wait(10) { abs(self.seconds(elapsed.label) - before) <= 2 })
        let slider = app.descendants(matching: .any)["fullPlayer.progress"].firstMatch
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(wait(10) { self.seconds(elapsed.label) > 20 && self.seconds(remaining.label) > 15 })
        XCTAssertEqual(play.label, "Play")
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "retained-audio-full-duration-paused-seek"
        capture.lifetime = .keepAlways
        add(capture)
    }

    private func seconds(_ text: String) -> Int {
        text.replacingOccurrences(of: "≈ ", with: "").replacingOccurrences(of: "-", with: "")
            .split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
    private func wait(_ timeout: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout) == .completed
    }
}
