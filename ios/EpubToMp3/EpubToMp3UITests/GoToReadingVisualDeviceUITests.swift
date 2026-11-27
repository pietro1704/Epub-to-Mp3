import XCTest

/// PLAYER-GO-TO-READING-PAGE on a physical iPhone, with the real library: while narrating, turn the reader away from
/// the spoken passage; the expanded player then shows the filled "Go to reading" button; tapping it opens the reader
/// at the narration, where the button is gone again. Screenshots of both states are attached as visual evidence.
@MainActor
final class GoToReadingVisualDeviceUITests: XCTestCase {
    private let bookTile = "library.bookTile.ff676d7fa5b703fb8d4c6708fad2d52b"

    func testGoToReadingButtonShowsWhenDivergedAndLeadsBackToTheNarration() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real narration on a physical iPhone.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-reader.recentTool.v1", "listen",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let closePlayer = app.buttons["fullPlayer.close"].firstMatch
        if closePlayer.waitForExistence(timeout: 3) { closePlayer.tap() }
        let libraryTab = app.tabBars.buttons["Library"]
        if libraryTab.waitForExistence(timeout: 5) { libraryTab.tap() }
        let tile = app.descendants(matching: .any)[bookTile].firstMatch
        let grid = app.collectionViews.firstMatch
        for _ in 0..<10 where !tile.waitForExistence(timeout: 2) && grid.exists { grid.swipeUp() }
        XCTAssertTrue(tile.waitForExistence(timeout: 20), "The retained Jardim das Aflições EPUB must be in the device library.")
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["reader.more"].firstMatch.waitForExistence(timeout: 90), "The reader must open.")

        let toolbarListen = app.navigationBars.buttons["reader.listen"].firstMatch
        XCTAssertTrue(toolbarListen.waitForExistence(timeout: 10))
        toolbarListen.tap()
        let fromPage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Listen from this page")).firstMatch
        if fromPage.waitForExistence(timeout: 5) { fromPage.tap() }
        let open = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 90), "Listening must show the mini player.")
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        open.tap()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntil(timeout: 240) { self.seconds(elapsed.label) >= 3 }, "Narration must start playing.")
        let goTo = app.buttons["fullPlayer.goToReading"].firstMatch
        attach("1-player-paired-on-the-narrated-page")
        XCTAssertFalse(goTo.exists && goTo.isHittable, "Paired reader: the button is hidden")

        // Leave the narrated page: close the player and turn the reader ahead several pages.
        app.buttons["fullPlayer.close"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            Thread.sleep(forTimeInterval: 0.7)
        }
        open.tap()
        XCTAssertTrue(goTo.waitForExistence(timeout: 15), "Diverged reader: the player offers Go to reading")
        XCTAssertTrue(goTo.isHittable)
        XCTAssertEqual(goTo.label, "Go to reading")
        attach("2-player-diverged-shows-go-to-reading")
        let rate = app.buttons["fullPlayer.playbackRateButton"].firstMatch
        XCTAssertGreaterThan(goTo.frame.minX, rate.frame.maxX - 1, "Right of the speed button")

        goTo.tap()
        XCTAssertTrue(app.buttons["fullPlayer.close"].firstMatch.waitForNonExistence(timeout: 10), "The player closes")
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        attach("3-reader-at-the-narration")
        open.tap()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 2)
        attach("4-player-paired-again")
        XCTAssertFalse(goTo.exists && goTo.isHittable, "Back on the narrated page the button is hidden again")
        #endif
    }

    private func seconds(_ clock: String) -> Int {
        guard let range = clock.range(of: #"\d+(:\d+)+"#, options: .regularExpression) else { return 0 }
        return clock[range].split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if condition() { return true }; Thread.sleep(forTimeInterval: 1) }
        return condition()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
