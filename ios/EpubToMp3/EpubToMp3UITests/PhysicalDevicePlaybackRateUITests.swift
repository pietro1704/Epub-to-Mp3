import XCTest

@MainActor
final class PhysicalDevicePlaybackRateUITests: XCTestCase {
    func testOptInDoubleSpeedPreservesPauseAndAdvancesPlayback() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_DOUBLE_SPEED"] == "1",
              let bookID = ProcessInfo.processInfo.environment["APP_DEVICE_LINK_BOOK_ID"] else {
            throw XCTSkip("Requires an installed long EPUB and authorized physical-device Piper playback.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        app.tabBars.buttons["Library"].tap()
        if let title = ProcessInfo.processInfo.environment["APP_DEVICE_LINK_BOOK_TITLE"] {
            let search = app.searchFields["library.searchField"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 10))
            search.tap()
            search.typeText(title + "\n")
        }
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
        let collection = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if tile.exists && tile.frame.intersection(collection.frame).height >= 80 { break }
            collection.swipeUp()
        }
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        let visible = tile.frame.intersection(collection.frame)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: visible.minY + 30)).tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        app.buttons["miniPlayer.playPause"].firstMatch.tap()
        let choice = app.buttons["From current page"].firstMatch
        if choice.waitForExistence(timeout: 2) { choice.tap() }
        app.buttons["miniPlayer.open"].firstMatch.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let transport = app.buttons["fullPlayer.playPause"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 60))
        XCTAssertTrue(wait(timeout: 90) { transport.label.lowercased() == "pause" })
        transport.tap()
        XCTAssertTrue(wait(timeout: 5) { transport.label.lowercased() == "play" })
        let paused = seconds(elapsed.label)
        let rate = app.buttons["fullPlayer.playbackRateButton"].firstMatch
        rate.tap()
        let doubleSpeed = app.buttons["2x"].firstMatch
        XCTAssertTrue(doubleSpeed.waitForExistence(timeout: 5))
        doubleSpeed.tap()
        XCTAssertEqual(transport.label.lowercased(), "play", "Selecting 2x must preserve explicit pause.")
        XCTAssertLessThanOrEqual(abs(seconds(elapsed.label) - paused), 1)
        XCTAssertTrue(rate.label.contains("2x") || (rate.value as? String ?? "").contains("2x") || rate.staticTexts["2x"].exists)
        transport.tap()
        XCTAssertTrue(wait(timeout: 30) { self.seconds(elapsed.label) >= paused + 2 })
        let started = ProcessInfo.processInfo.systemUptime
        let before = seconds(elapsed.label)
        let delay = expectation(description: "Observe actual double-speed playback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { delay.fulfill() }
        wait(for: [delay], timeout: 8)
        let wall = ProcessInfo.processInfo.systemUptime - started
        let advanced = seconds(elapsed.label) - before
        XCTAssertGreaterThanOrEqual(Double(advanced), wall * 1.6)
        XCTAssertLessThanOrEqual(Double(advanced), wall * 2.4)
        let measurement = XCTAttachment(string: "wall_seconds=\(wall), media_seconds=\(advanced)")
        measurement.lifetime = .keepAlways
        add(measurement)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "double-speed-playing"
        screen.lifetime = .keepAlways
        add(screen)
        transport.tap()
        XCTAssertTrue(wait(timeout: 5) { transport.label.lowercased() == "play" })
    }

    private func wait(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)],
                      timeout: timeout) == .completed
    }
    private func seconds(_ text: String) -> Int {
        text.replacingOccurrences(of: "≈ ", with: "").split(separator: ":")
            .reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }
}
