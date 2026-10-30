import XCTest

@MainActor
final class PhysicalDeviceApproximateSeekUITests: XCTestCase {
    func testOptInUnavailableSliderStartsNearDestination() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_APPROXIMATE_SEEK"] == "1",
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
        let progress = app.descendants(matching: .any)["fullPlayer.progress"].firstMatch
        XCTAssertTrue(progress.isHittable)
        let started = ProcessInfo.processInfo.systemUptime
        progress.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).tap()
        XCTAssertTrue(wait(timeout: 10) { elapsed.label.contains("≈") },
                      "The fixture must exercise unavailable audio, not a previously prepared target.")
        XCTAssertTrue(wait(timeout: 30) { transport.label.lowercased() == "pause" })
        let resumedAt = seconds(elapsed.label)
        XCTAssertTrue(wait(timeout: 10) { self.seconds(elapsed.label) >= resumedAt + 2 },
                      "The real audio clock must advance after the approximate jump.")
        let latency = ProcessInfo.processInfo.systemUptime - started
        let measurement = XCTAttachment(string: "slider_to_observed_playback_seconds=\(latency)")
        measurement.lifetime = .keepAlways
        add(measurement)
        let screen = XCTAttachment(screenshot: app.screenshot())
        screen.name = "approximate-slider-playing"
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
