import XCTest

/// Exercises the installed app without resetting books or playback state.
@MainActor
final class PhysicalLibraryViewportTests: XCTestCase {
    func testLibraryGridStopsAboveVisibleMiniPlayer() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_AUDIOBOOK_ACCEPTANCE"] == "1",
              ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] == "com.pietrocode.epubtomp3" else {
            throw XCTSkip("Requires the explicitly authorized installed physical iPhone app")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone only")
        #else
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let close = app.buttons["fullPlayer.close"]
        if close.waitForExistence(timeout: 3) { close.tap() }
        let library = app.tabBars.buttons["Library"]
        if !library.waitForExistence(timeout: 3) {
            let browse = app.buttons["mainReader.browseLibrary"]
            XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
            browse.tap()
        }
        XCTAssertTrue(library.waitForExistence(timeout: 10), app.debugDescription)
        library.tap()
        let grid = app.collectionViews.firstMatch
        let miniPlayer = app.descendants(matching: .any)["miniPlayer.bar"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), app.debugDescription)
        if !miniPlayer.exists {
            let fixture = app.cells["library.bookTile.7c135a6d930d789aaadede9a02cdc8aa"]
            XCTAssertTrue(fixture.exists, "Requires the installed Piper Live Portuguese acceptance fixture")
            fixture.tap()
            let transport = app.buttons["miniPlayer.playPause"].firstMatch
            XCTAssertTrue(transport.waitForExistence(timeout: 30), app.debugDescription)
            transport.tap()
            let playing = NSPredicate { _, _ in transport.label.lowercased() == "pause" }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: playing, object: nil)], timeout: 60), .completed)
            transport.tap()
            app.buttons["reader.close"].tap()
            XCTAssertTrue(library.waitForExistence(timeout: 10), app.debugDescription)
            library.tap()
        }
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 10), "Requires retained playback state: \(app.debugDescription)")
        let fits = NSPredicate { _, _ in grid.frame.maxY <= miniPlayer.frame.minY + 1 }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fits, object: nil)], timeout: 5), .completed,
                       "Grid \(grid.frame) overlaps mini player \(miniPlayer.frame)")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "library-grid-above-visible-mini-player"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "library-viewport-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        #endif
    }
}
