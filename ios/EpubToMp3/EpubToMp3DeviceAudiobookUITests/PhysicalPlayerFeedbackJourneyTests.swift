import XCTest

/// Exercises the installed app and its existing authored Portuguese book.
/// No fixture replacement, model installation or preference reset is performed.
@MainActor
final class PhysicalPlayerFeedbackJourneyTests: XCTestCase {
    func testInstalledPlayerControlsAndPausedSeeking() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_AUDIOBOOK_ACCEPTANCE"] == "1",
              ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] == "com.pietrocode.epubtomp3" else {
            throw XCTSkip("Requires the authorized installed iPhone app")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        for identifier in ["fullPlayer.close", "reader.close", "mainReader.browseLibrary"] {
            let button = app.buttons[identifier].firstMatch
            if button.exists && button.isHittable { button.tap() }
        }
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), app.debugDescription)
        library.tap()
        let book = app.cells["library.bookTile.7c135a6d930d789aaadede9a02cdc8aa"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10), "The existing Piper Live Portuguese acceptance book is required")
        let grid = app.collectionViews.firstMatch
        for _ in 0..<8 where !book.isHittable { grid.swipeUp() }
        XCTAssertTrue(book.isHittable)
        book.tap()
        XCTAssertTrue(app.buttons["reader.search"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        capture(app, "reader-before-audio")

        let miniRate = app.buttons["miniPlayer.rate"].firstMatch
        XCTAssertTrue(miniRate.waitForExistence(timeout: 10))
        miniRate.tap()
        let normal = app.buttons["1x"].firstMatch
        XCTAssertTrue(normal.waitForExistence(timeout: 5), "The normal speed must be available in the mini player")
        normal.tap()
        let play = app.buttons["miniPlayer.playPause"].firstMatch
        let pausedLabel = play.label
        play.tap()
        let pageChoice = app.buttons["From current page"].firstMatch
        if pageChoice.waitForExistence(timeout: 2) { pageChoice.tap() }
        app.buttons["miniPlayer.open"].firstMatch.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let transport = app.buttons["fullPlayer.playPause"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 15))
        XCTAssertTrue(wait(90) { self.seconds(elapsed.label) >= 2 }, "Actual media time must advance")
        capture(app, "actual-audio-playing")
        transport.tap()
        XCTAssertTrue(wait(5) { transport.label == pausedLabel || ["play", "reproduzir"].contains(transport.label.lowercased()) })
        let stoppedLabel = transport.label
        let paused = seconds(elapsed.label)
        let delay = expectation(description: "Observe an explicit pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { delay.fulfill() }
        wait(for: [delay], timeout: 3)
        XCTAssertLessThanOrEqual(abs(seconds(elapsed.label) - paused), 1)

        let rate = app.buttons["fullPlayer.playbackRateButton"].firstMatch
        rate.tap()
        XCTAssertTrue(app.buttons["1x"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "normal-speed-menu")
        app.buttons["1x"].firstMatch.tap()
        XCTAssertEqual(transport.label, stoppedLabel, "Changing speed must preserve pause")

        app.buttons["fullPlayer.skipForward"].firstMatch.tap()
        XCTAssertTrue(wait(60) { self.seconds(elapsed.label) >= paused + 10 }, "Forward transport must move the actual paused position")
        app.buttons["fullPlayer.skipBack"].firstMatch.tap()
        XCTAssertTrue(wait(30) { self.seconds(elapsed.label) <= paused + 2 })
        XCTAssertEqual(transport.label, stoppedLabel)
        capture(app, "paused-transport-round-trip")

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(wait(8) {
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            })
            for identifier in ["fullPlayer.close", "fullPlayer.playPause", "fullPlayer.skipBack", "fullPlayer.skipForward"] {
                let button = app.buttons[identifier].firstMatch
                XCTAssertTrue(button.isHittable)
                XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame))
            }
            capture(app, "player-orientation-\(orientation.rawValue)")
        }
        app.buttons["fullPlayer.close"].firstMatch.tap()
        XCTAssertTrue(app.buttons["reader.search"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "reader-after-player-dismissal")
        #endif
    }

    private func wait(_ seconds: TimeInterval, _ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: seconds) == .completed
    }

    private func seconds(_ text: String) -> Int {
        text.replacingOccurrences(of: "≈ ", with: "").split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
