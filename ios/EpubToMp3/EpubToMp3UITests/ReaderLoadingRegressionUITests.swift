import XCTest

/// Visual regressions for the reader's three critical states: library,
/// bounded loading cover, and a usable paginated page with the mini-player.
@MainActor
final class ReaderLoadingRegressionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testReaderBackReturnsToInteractiveLibrary() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixture(delayMilliseconds: 8_000)
        let firstBook = try firstBook(in: app)
        firstBook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()

        let loadingCover = app.images["reader.loadingCover"].firstMatch
        XCTAssertTrue(loadingCover.waitForExistence(timeout: 5), "Reader must show its loading state before its back button can be tested.")

        let navigationBar = app.navigationBars["reader.navigationBar"].firstMatch
        let backButton = app.buttons["reader.close"].firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Reader must expose a native back button.")
        backButton.tap()

        XCTAssertTrue(
            navigationBar.waitForNonExistence(timeout: 5),
            "Reader navigation must disappear after tapping Back."
        )
        XCTAssertTrue(
            firstBook.isHittable,
            "Back must return to an interactive Library, not leave its reader overlay in front."
        )
    }

    func testLoadingThenReaderContentAndProductionTaps() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixture(delayMilliseconds: 8_000)
        let firstBook = try firstBook(in: app)
        attach("01-library", app: app)

        // The mini player can cover the lower portion of a tall grid cell.
        // Open from the visible cover area, as a person does, rather than
        // relying on XCTest's cell-center tap.
        firstBook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let cover = app.images["reader.loadingCover"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "Opening a book must show its loading cover.")
        attach("02-loading", app: app)
        assertBoundedLoadingCover(cover, in: app)
        app.swipeLeft()
        XCTAssertTrue(cover.exists, "Reader navigation must remain blocked while loading is visible.")

        XCTAssertTrue(cover.waitForNonExistence(timeout: 10), "Loading cover must disappear after content is laid out.")
        attach("03-reader-after-loading", app: app)
        let indicator = app.staticTexts["reader.pageIndicator"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 5), "Paginated reader must expose a page indicator.")
        XCTAssertGreaterThan(pageNumbers(indicatorValue(indicator)).last ?? 0, 1, "Fixture must produce multiple pages.")

        let navigationBar = app.navigationBars["reader.navigationBar"].firstMatch
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(navigationBar.exists, "Reader navigation bar must remain discoverable for layout validation.")
        XCTAssertGreaterThanOrEqual(
            viewport.frame.minY,
            navigationBar.frame.maxY,
            "Reader content must begin below the navigation bar."
        )

        let miniPlayer = app.otherElements["miniPlayer.bar"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "Reader must restore its mini-player after loading.")
        XCTAssertGreaterThanOrEqual(
            miniPlayer.frame.height,
            52,
            "Reader mini-player must retain its intrinsic control height."
        )
        let miniPlayerOpen = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(
            (miniPlayerOpen.value as? String)?.contains("Chapter One") ?? false,
            "Mini-player must use the reader's canonical chapter title."
        )
        attach("03-reader-ready", app: app)

        let initialIndicatorValue = indicatorValue(indicator)
        let initialPage = pageNumbers(initialIndicatorValue).first ?? 0
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.50)).tap()
        let pageAdvanced = NSPredicate(format: "value != %@", initialIndicatorValue)
        expectation(for: pageAdvanced, evaluatedWith: indicator)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(pageNumbers(indicatorValue(indicator)).first ?? 0, initialPage,
                             "A real right-side screen tap must advance the page.")

        let search = app.buttons["reader.search"].firstMatch
        XCTAssertTrue(search.exists, "Reader chrome should initially be visible.")
        // This is intentionally above the vertical midpoint. The middle
        // column must toggle chrome regardless of y position.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.28)).tap()
        XCTAssertTrue(search.waitForNonExistence(timeout: 3), "Middle-column tap must hide reader chrome.")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.28)).tap()
        XCTAssertTrue(search.waitForExistence(timeout: 3), "Second middle-column tap must restore reader chrome.")
    }

    func testLoadingCoverFitsLandscapeSafeViewport() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixture(delayMilliseconds: 8_000)
        let firstBook = try firstBook(in: app)
        firstBook.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()

        let cover = app.images["reader.loadingCover"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "Loading cover must remain visible long enough to inspect.")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(cover.waitForExistence(timeout: 5), "Loading cover must survive an in-flight rotation.")
        assertBoundedLoadingCover(cover, in: app)
        attach("04-loading-landscape", app: app)
    }

    func testFullPlayerFitsCurrentCompactScreen() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = launchFixture(delayMilliseconds: 0, includesPlaybackFixture: true)

        let miniPlayer = app.otherElements["miniPlayer.bar"].firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        attach("05-mini-player-before-expand", app: app)
        // The user-facing expansion target is the cover/title area, not a
        // transport control. Exercise that contract in the iOS 26 tab
        // accessory as well as in the reader overlay.
        miniPlayer.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).tap()
        sleep(1)
        attach("06-full-player-after-expand", app: app)

        let close = app.buttons["fullPlayer.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Tapping the mini-player must open the full player.")
        XCTAssertTrue(close.isHittable, "Full-player dismissal must remain reachable on a compact screen.")
        let rate = app.buttons["fullPlayer.playbackRateButton"].firstMatch
        XCTAssertTrue(rate.waitForExistence(timeout: 5), "Full-player secondary controls must exist on a compact screen.")
        XCTAssertTrue(rate.isHittable, "Full-player secondary controls must remain reachable on a compact screen.")
        let window = app.windows.firstMatch
        XCTAssertLessThanOrEqual(close.frame.maxY, window.frame.maxY, "Full-player dismissal must stay inside the viewport.")
        XCTAssertLessThanOrEqual(rate.frame.maxY, window.frame.maxY, "Full-player secondary controls must stay inside the viewport.")
        attach("05-full-player-compact", app: app)
    }

    private func launchFixture(delayMilliseconds: Int, includesPlaybackFixture: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestFixture",
            "-uiTestResetReaderPosition",
            "-uiTestReaderLayout", "paginated",
            "-uiTestReaderShowPageNumbers",
            "-uiTestNoPageTurnOverlay",
            "-uiTestLoadingDelayMilliseconds", String(delayMilliseconds),
        ]
        if includesPlaybackFixture {
            app.launchArguments.append("-uiTestPlaybackFixture")
        }
        app.launch()
        return app
    }

    private func firstBook(in app: XCUIApplication) throws -> XCUIElement {
        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 10) else {
            throw XCTSkip("The deterministic UI-test library fixture is unavailable.")
        }
        return firstBook
    }

    private func assertBoundedLoadingCover(_ cover: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let overlay = app.otherElements["reader.loadingOverlay"].firstMatch
        let geometry = "cover=\(cover.frame), overlay=\(overlay.frame), window=\(window.frame)"
        XCTAssertLessThanOrEqual(
            cover.frame.width,
            window.frame.width * 0.61,
            "Loading cover must never consume the reader width."
        )
        XCTAssertLessThanOrEqual(
            cover.frame.height,
            window.frame.height * 0.43,
            "Loading cover must fit a short or landscape viewport."
        )
        XCTAssertEqual(
            cover.frame.height / cover.frame.width,
            1.5,
            accuracy: 0.02,
            "Loading cover must preserve its book aspect ratio."
        )
        XCTAssertLessThanOrEqual(
            cover.frame.midY,
            window.frame.midY,
            "Loading cover must stay in the upper reading area, not drift below the viewport center (\(geometry))."
        )
        XCTAssertGreaterThanOrEqual(cover.frame.minY, window.frame.minY)
        XCTAssertLessThanOrEqual(cover.frame.maxY, window.frame.maxY)
    }

    private func pageNumbers(_ label: String) -> [Int] {
        label
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
    }

    private func indicatorValue(_ indicator: XCUIElement) -> String {
        indicator.value as? String ?? indicator.label
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
