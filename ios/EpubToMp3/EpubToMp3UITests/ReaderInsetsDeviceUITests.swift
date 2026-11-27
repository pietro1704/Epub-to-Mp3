import XCTest

/// READER-PAGINATED-INSETS on a physical iPhone: in paginated mode the text surface always lies BELOW the top bar and
/// ABOVE the mini player, so no line is ever half hidden behind them, and showing/hiding the chrome never moves it.
@MainActor
final class ReaderInsetsDeviceUITests: XCTestCase {
    private let bookTile = "library.bookTile.ff676d7fa5b703fb8d4c6708fad2d52b"

    func testPaginatedTextAlwaysSitsBetweenTheBarsAndNeverMovesWithTheChrome() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device layout evidence.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-uiTestReaderLayout", "paginated",
                               "-uiTestChromeToggle", "-reader.recentTool.v1", "listen", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
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
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 90), "The reader must open.")
        let navigation = app.navigationBars["reader.navigationBar"].firstMatch
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(navigation.waitForExistence(timeout: 5), "Chrome must be visible")
        attach("1-chrome-visible")
        let shown = viewport.frame
        XCTAssertGreaterThanOrEqual(shown.minY, navigation.frame.maxY - 0.5,
                                    "The text surface starts below the top bar (viewport \(shown), bar \(navigation.frame))")

        // Hide the chrome: the surface (and so every line) keeps its place.
        let harness = ReaderModesHarness(app: app)
        harness.toggleChrome()
        let hidden = navigation.waitForNonExistence(timeout: 6)
        attach("2-chrome-toggled-hidden=\(hidden)")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(viewport.frame.minY, shown.minY, accuracy: 0.5, "Hiding the chrome must not move the text surface")
        XCTAssertEqual(viewport.frame.maxY, shown.maxY, accuracy: 0.5)
        harness.toggleChrome()
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))

        // With narration the mini player sits at the bottom: the surface ends above it.
        let toolbarListen = app.navigationBars.buttons["reader.listen"].firstMatch
        XCTAssertTrue(toolbarListen.waitForExistence(timeout: 10))
        toolbarListen.tap()
        let fromPage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Listen from this page")).firstMatch
        if fromPage.waitForExistence(timeout: 5) { fromPage.tap() }
        let miniPlayer = app.otherElements["miniPlayer.bar"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 90), "Listening must show the mini player.")
        Thread.sleep(forTimeInterval: 2)
        attach("3-mini-player")
        XCTAssertLessThanOrEqual(viewport.frame.maxY, miniPlayer.frame.minY + 0.5,
                                 "The text surface ends above the mini player (viewport \(viewport.frame), player \(miniPlayer.frame))")
        #endif
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
