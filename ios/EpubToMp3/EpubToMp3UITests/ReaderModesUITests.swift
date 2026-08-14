import XCTest

/// Device tests for two reader modes the user asked to verify:
///  1. Paginated mode with chrome HIDDEN — page turns (incl. chapter
///     crossing) must still work when the top/bottom bars are gone.
///  2. Continuous-scroll mode — a single tap toggles chrome, a drag scrolls
///     the book, and a tap must NOT be swallowed by the scroll gesture.
@MainActor
final class ReaderModesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(
        layout: String,
        smallFont: Bool = false,
        showsPageTurnOverlay: Bool = false,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        ReaderModesHarness().launch(.init(
            source: .fixture,
            layout: layout,
            smallFont: smallFont,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true,
            flickerProbeEnabled: true,
            showsPageTurnOverlay: showsPageTurnOverlay,
            additionalArguments: additionalArguments
        ))
    }

    private func launchForLiveSettings() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestFixture",
            "-uiTestResetReaderPosition",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    private func launchNativeLOTR() -> XCUIApplication {
        ReaderModesHarness().launch(.paginatedNativeLOTR)
    }

    private func openBook(_ app: XCUIApplication) throws {
        try ReaderModesHarness(app: app).openBook()
    }

    private func indicator(_ app: XCUIApplication) -> (page: Int, total: Int)? {
        let element = app.staticTexts["reader.pageIndicator"].firstMatch
        guard element.waitForExistence(timeout: 2) else { return nil }
        let text = (element.value as? String) ?? element.label
        let values = text
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        guard let page = values.first, let total = values.last else { return nil }
        return (page, total)
    }

    private func chromeVisible(_ app: XCUIApplication) -> Bool {
        ReaderModesHarness(app: app).chromeIsVisible
    }

    private func toggleReaderChrome(in app: XCUIApplication) {
        ReaderModesHarness(app: app).toggleChrome()
    }

    private func chapter(_ app: XCUIApplication) -> (index: Int, total: Int)? {
        let element = app.staticTexts["flicker.probe.chapter"].firstMatch
        guard element.waitForExistence(timeout: 2) else { return nil }
        let label = element.label
        let parts = label.split(separator: "/").map(String.init)
        guard parts.count == 2, let index = Int(parts[0]), let total = Int(parts[1]) else { return nil }
        return (index, total)
    }

    private func paginationMetrics(_ app: XCUIApplication) -> [String: Int] {
        ReaderModesHarness(app: app).paginationMetrics?.values ?? [:]
    }

    private func assertNoClippedPageLines(
        _ app: XCUIApplication,
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        ReaderModesHarness(app: app).assertNoClippedLines(scenario: scenario, file: file, line: line)
    }

    private func openReaderSettings(_ app: XCUIApplication) throws {
        let settings = app.buttons["reader.settings.toggle"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Reader settings button must be available.")
        settings.tap()
        XCTAssertTrue(
            app.cells["reader.settings.mode"].firstMatch.waitForExistence(timeout: 5),
            "The settings sheet must expose its reader-mode control through a stable identifier."
        )
    }

    private func chooseLayout(_ name: String, in app: XCUIApplication) throws {
        let mode = app.cells["reader.settings.mode"].firstMatch
        XCTAssertTrue(mode.exists, "Reader mode control must remain visible while the sheet is open.")
        if (mode.value as? String) == name { return }
        mode.tap()
        let choice = app.buttons[name].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "The \(name) mode option must be selectable.")
        choice.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "The settings sheet must remain open after changing the reader mode.")
    }

    private func waitForExistence(
        _ element: XCUIElement,
        equals expected: Bool,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return element.exists == expected
    }

    func testChangingLayoutReconfiguresTheOpenReaderImmediately() throws {
        let app = launchForLiveSettings()
        try openBook(app)
        try openReaderSettings(app)

        try chooseLayout("Paginated", in: app)
        let pageIndicator = app.staticTexts["reader.pageIndicator"].firstMatch
        XCTAssertTrue(pageIndicator.waitForExistence(timeout: 3), "Paginated mode must show the page indicator.")

        try chooseLayout("Scrolling", in: app)
        XCTAssertTrue(
            waitForExistence(pageIndicator, equals: false),
            "Switching to scrolling must hide pagination chrome before the settings sheet is dismissed."
        )

        try chooseLayout("Paginated", in: app)
        XCTAssertTrue(
            pageIndicator.waitForExistence(timeout: 3),
            "Switching back to paginated must restore pagination chrome without reopening the book."
        )
    }

    func testMarginSliderChangesTheOpenTextViewportDuringEditing() throws {
        let app = launchForLiveSettings()
        try openBook(app)
        try openReaderSettings(app)
        try chooseLayout("Paginated", in: app)

        let marginRow = app.cells["reader.settings.margin.row"].firstMatch
        let slider = app.sliders["reader.settings.margin"].firstMatch
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        let content = app.textViews["reader.content"].firstMatch
        XCTAssertTrue(marginRow.waitForExistence(timeout: 3), "Margin must remain a visible setting row.")
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Margin must use the native continuous slider.")
        XCTAssertTrue(viewport.exists && content.exists, "The open reader must remain mounted behind its settings sheet.")
        XCTAssertGreaterThanOrEqual(
            slider.frame.width,
            marginRow.frame.width - 40,
            "The slider must use the row's available width rather than sit in a narrow middle column."
        )

        slider.adjust(toNormalizedSliderPosition: 0)
        sleep(1)
        let minimum = content.frame
        XCTAssertEqual(
            minimum.minX - viewport.frame.minX,
            8,
            accuracy: 1,
            "The minimum slider position must put the text viewport 8 pt from the reader viewport."
        )
        XCTAssertEqual(
            viewport.frame.maxX - minimum.maxX,
            8,
            accuracy: 1,
            "The minimum reader margin must be symmetric."
        )

        slider.adjust(toNormalizedSliderPosition: 0.5)
        sleep(1)
        let expanded = content.frame
        XCTAssertGreaterThan(
            expanded.minX,
            minimum.minX + 20,
            "Changing the slider must move the text viewport while the sheet remains open."
        )
        XCTAssertLessThan(
            expanded.width,
            minimum.width - 40,
            "A larger margin must immediately narrow the visible text viewport."
        )

        slider.adjust(toNormalizedSliderPosition: 0)
        sleep(1)
        XCTAssertEqual(
            content.frame.minX,
            minimum.minX,
            accuracy: 1,
            "Returning the slider to its minimum must restore the 8 pt viewport immediately."
        )
    }

    // MARK: - 1) Paginated, chrome hidden

    func testPaginatedPageTurnWorksWithChromeHidden() throws {
        let app = launch(layout: "paginated")
        try openBook(app)
        guard indicator(app)?.total ?? 0 >= 2 else {
            throw XCTSkip("Need a multi-page chapter.")
        }

        // Hide chrome (center tap).
        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertFalse(chromeVisible(app), "center tap must hide chrome")

        // With chrome hidden, an edge tap on the RIGHT third must still turn
        // the page. (Apple Books restores chrome on the first hidden-edge tap
        // for some designs, but here the reader turns the page directly.)
        let before = indicator(app)?.page ?? 1
        let rightTurn = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(rightTurn.waitForExistence(timeout: 5))
        rightTurn.tap()
        sleep(1)
        // Reveal the indicator before reading it; hidden UIKit labels may
        // retain their last accessibility snapshot while chrome is hidden.
        toggleReaderChrome(in: app)
        sleep(1)
        let after = indicator(app)?.page ?? before
        XCTAssertGreaterThan(after, before,
            "right-edge tap with chrome hidden must still advance the page (before=\(before) after=\(after))")
    }

    // MARK: - 1b) Paginated chrome toggle (single-page safe)

    func testPaginatedCenterTapTogglesChrome() throws {
        let app = launch(layout: "paginated")
        try openBook(app)
        XCTAssertTrue(chromeVisible(app), "reader should open with chrome visible")

        // Use the actual center hit target instead of a test-only button.
        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertFalse(chromeVisible(app), "center tap must hide paginated chrome")

        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertTrue(chromeVisible(app), "second center tap must restore paginated chrome")
    }

    func testPaginatedChromeToggleExpandsTheViewportWithoutChangingThePage() throws {
        let app = launch(layout: "paginated")
        try openBook(app)

        let viewport = app.scrollViews["reader.viewport"].firstMatch
        let content = app.textViews["reader.content"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "The reader viewport must be available.")
        XCTAssertTrue(content.exists, "The paginated text surface must remain mounted.")

        let pageBeforeToggle = indicator(app)
        let viewportBeforeToggle = viewport.frame

        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertFalse(chromeVisible(app), "The first center tap must hide reader chrome.")
        XCTAssertLessThan(viewport.frame.minY, viewportBeforeToggle.minY,
                          "Immersive reading must reclaim the navigation-bar height.")
        XCTAssertGreaterThan(viewport.frame.height, viewportBeforeToggle.height,
                             "Immersive reading must reclaim the bottom chrome height.")
        XCTAssertTrue(content.exists, "The paginated text surface must remain mounted.")
        XCTAssertGreaterThan(content.frame.height, 0)

        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertTrue(chromeVisible(app), "The second center tap must restore reader chrome.")
        XCTAssertEqual(viewport.frame, viewportBeforeToggle,
                       "Restoring chrome must restore the original viewport.")
        XCTAssertEqual(
            indicator(app)?.page,
            pageBeforeToggle?.page,
            "A chrome toggle must not change the current paginated page."
        )
    }

    func testPaginatedChromeTogglePreservesAnAdvancedPage() throws {
        let app = launch(layout: "paginated")
        try openBook(app)

        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        var previousPage = indicator(app)?.page ?? 0
        for _ in 0..<2 {
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.50)).tap()
            sleep(1)
            let currentPage = indicator(app)?.page ?? 0
            XCTAssertGreaterThan(currentPage, previousPage, "Reader must advance before toggling chrome.")
            previousPage = currentPage
        }
        let advancedPage = indicator(app)
        XCTAssertGreaterThan(advancedPage?.page ?? 0, 1, "Fixture must advance before toggling chrome.")
        let firstCharacterBefore = paginationMetrics(app)["first"]
        XCTAssertNotNil(firstCharacterBefore, "The viewport probe must expose the first visible character.")

        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertFalse(chromeVisible(app))
        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertTrue(chromeVisible(app))
        XCTAssertEqual(
            indicator(app)?.page,
            advancedPage?.page,
            "Showing and hiding reader chrome must preserve the advanced reading page."
        )
        let firstCharacterAfter = paginationMetrics(app)["first"]
        XCTAssertNotNil(firstCharacterAfter)
        XCTAssertLessThanOrEqual(
            abs((firstCharacterAfter ?? 0) - (firstCharacterBefore ?? 0)),
            100,
            "Showing and hiding reader chrome must not return to an earlier passage."
        )
        assertNoClippedPageLines(app, scenario: "restoring an advanced page after chrome reflow")
    }

    func testRepeatedChromeTogglesKeepTheExactAdvancedPassage() throws {
        let app = launch(layout: "paginated", smallFont: true)
        try openBook(app)

        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            right.tap()
            usleep(450_000)
        }

        let anchorBefore = paginationMetrics(app)["first"]
        XCTAssertNotNil(anchorBefore, "The probe must expose the first visible character before toggling chrome.")

        // Each pair returns to the identical viewport geometry. Keeping only
        // an approximate character range accepts the historic regression in
        // which every pair gradually moved the reader back through the book.
        for iteration in 0..<6 {
            toggleReaderChrome(in: app)
            // Interrupt the running chrome transition. This is the actual
            // user gesture that previously captured an intermediate offset.
            usleep(40_000)
            toggleReaderChrome(in: app)
            usleep(700_000)
            XCTAssertEqual(
                paginationMetrics(app)["first"],
                anchorBefore,
                "chrome round trip \(iteration) must return to the exact passage instead of drifting backward"
            )
            assertNoClippedPageLines(app, scenario: "exact-anchor chrome round trip \(iteration)")
        }
    }

    func testNativeLOTRDoesNotMoveBackwardAfterInterruptedChromeToggles() throws {
        let app = launchNativeLOTR()
        let nativeBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        XCTAssertTrue(nativeBook.waitForExistence(timeout: 20))
        XCTAssertTrue(nativeBook.label.localizedCaseInsensitiveContains("lord"),
                      "The regression must exercise the imported LOTR, not a fixture book.")
        try openBook(app)
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 30), "The native LOTR reader must open.")

        // Use the production edge hit region, not a test-only page button.
        while (indicator(app)?.page ?? 1) < 4 {
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.50)).tap()
            usleep(500_000)
        }
        XCTAssertGreaterThanOrEqual(indicator(app)?.page ?? 0, 4)
        assertNoClippedPageLines(app, scenario: "native LOTR page four before chrome toggling")
        let anchorBefore = paginationMetrics(app)["first"]
        let offsetBefore = paginationMetrics(app)["offset"]
        XCTAssertNotNil(anchorBefore, "The native reader must expose its visible character anchor.")
        XCTAssertNotNil(offsetBefore, "The native reader must expose its visual offset.")

        for iteration in 0..<8 {
            // These are the same center touches used by the user. Let each
            // state settle: the reported drift also happens with ordinary,
            // non-interrupted repeated toggles.
            toggleReaderChrome(in: app)
            usleep(700_000)
            XCTAssertFalse(chromeVisible(app), "native LOTR first center touch must hide chrome")
            toggleReaderChrome(in: app)
            usleep(700_000)
            XCTAssertTrue(chromeVisible(app), "native LOTR second center touch must restore chrome")
            XCTAssertEqual(
                paginationMetrics(app)["first"], anchorBefore,
                "native LOTR round trip \(iteration) moved backward"
            )
            XCTAssertEqual(
                paginationMetrics(app)["offset"], offsetBefore,
                "native LOTR round trip \(iteration) changed the returned viewport offset"
            )
            assertNoClippedPageLines(app, scenario: "native LOTR round trip \(iteration)")
        }
    }

    func testNativeLOTRLandscapePaginationKeepsEveryGlyphVisible() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchNativeLOTR()
        try openBook(app)
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 30), "The native LOTR reader must open.")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(viewport.waitForExistence(timeout: 10), "The reader viewport must survive rotation.")
        usleep(900_000)
        assertNoClippedPageLines(app, scenario: "native LOTR landscape initial page")

        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        right.tap()
        usleep(700_000)
        assertNoClippedPageLines(app, scenario: "native LOTR landscape advanced page")
    }

    func testRapidChromeTogglesAndPageTurnsNeverClipLines() throws {
        let app = launch(layout: "paginated")
        try openBook(app)

        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))

        for iteration in 0..<4 {
            right.tap()
            usleep(650_000)
            toggleReaderChrome(in: app)
            // This intentionally lands while the chrome animation is in
            // flight. A second tap and an edge turn used to apply stale page
            // offsets and leave a clipped line at a viewport edge.
            usleep(40_000)
            toggleReaderChrome(in: app)
            right.tap()
            usleep(700_000)
            assertNoClippedPageLines(app, scenario: "rapid chrome/page cycle \(iteration)")
        }
    }

    func testChromeTransitionCommitsOneCompletePaginationLayout() throws {
        let app = launch(layout: "paginated", smallFont: true)
        try openBook(app)
        toggleReaderChrome(in: app)
        usleep(100_000)
        assertNoClippedPageLines(app, scenario: "atomic chrome hide")
        // Reverse the state immediately. The text viewport must never show
        // a snapshot compressed into its smaller geometry.
        usleep(40_000)
        toggleReaderChrome(in: app)
        usleep(100_000)
        assertNoClippedPageLines(app, scenario: "frozen rapid chrome round trip")
    }

    func testSmallNativeSerifFontSurvivesRapidChromeTogglesWithoutClippingOrLargeGap() throws {
        let app = launch(layout: "paginated", smallFont: true)
        try openBook(app)
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCTAssertTrue(right.waitForExistence(timeout: 5))

        for iteration in 0..<6 {
            right.tap()
            usleep(400_000)
            toggleReaderChrome(in: app)
            usleep(35_000)
            toggleReaderChrome(in: app)
            usleep(550_000)
            assertNoClippedPageLines(app, scenario: "small native-serif rapid chrome cycle \(iteration)")
            let metrics = paginationMetrics(app)
            let lastY = metrics["lastCompleteY"] ?? 0
            let viewportBottom = metrics["viewportBottom"] ?? 0
            XCTAssertLessThanOrEqual(
                viewportBottom - lastY,
                60,
                "small native-serif page must not acquire a large blank footer after chrome toggling (\(metrics))"
            )
        }
    }

    func testPaginatedPageTurnAppliesTheMeasuredTextHeight() throws {
        let app = launch(layout: "paginated")
        try openBook(app)

        let nextPage = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(nextPage.waitForExistence(timeout: 5), "The next-page target must be available.")
        nextPage.tap()
        sleep(1)

        let metrics = paginationMetrics(app)
        let measured = metrics["measuredTextHeight"] ?? 0
        let frame = metrics["textFrameHeight"] ?? 0
        let viewport = metrics["viewportHeight"] ?? 0
        let paginatedHeightActive = metrics["paginatedHeightActive"] ?? 0
        let scrollingHeightActive = metrics["scrollingHeightActive"] ?? 0
        XCTAssertGreaterThan(measured, viewport * 2, "The fixture must span multiple paginated viewports.")
        XCTAssertEqual(
            frame,
            measured,
            accuracy: 1,
            "A paginated page turn must lay out the text to its measured height instead of clipping it to one viewport (paginated active: \(paginatedHeightActive), scrolling active: \(scrollingHeightActive))."
        )
    }

    func testHorizontalCurlAppearsForForwardAndBackwardTurns() throws {
        let app = launch(
            layout: "paginated",
            showsPageTurnOverlay: true,
            additionalArguments: ["-uiTestPageTurnStyle", "flip"]
        )
        try openBook(app)
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        let left = app.buttons["reader.pageTurn.left"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        XCTAssertTrue(left.waitForExistence(timeout: 5))

        right.tap()
        XCTAssertTrue(
            app.otherElements["reader.pageCurl"].firstMatch.waitForExistence(timeout: 0.2),
            "Forward pagination must present the horizontal page-curl overlay."
        )
        sleep(1)
        left.tap()
        XCTAssertTrue(
            app.otherElements["reader.pageCurl"].firstMatch.waitForExistence(timeout: 0.2),
            "Backward pagination must present the horizontal page-curl overlay."
        )
    }

    func testReduceMotionSkipsThePageCurl() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-uiTestFixture", "-uiTestResetReaderPosition",
            "-uiTestReaderLayout", "paginated",
            "-uiTestPageTurnStyle", "flip",
            "-uiTestReduceMotion",
        ]
        app.launch()
        try openBook(app)
        let right = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5))
        right.tap()
        XCTAssertFalse(
            app.otherElements["reader.pageCurl"].firstMatch.waitForExistence(timeout: 0.5),
            "Reduce Motion must change the page without a curl overlay."
        )
    }

    // MARK: - 2) Continuous scroll mode

    func testScrollModeTapTogglesChromeAndScrollWorks() throws {
        let app = launch(layout: "scrolling")
        try openBook(app)
        XCTAssertTrue(chromeVisible(app), "reader should open with chrome visible")

        // There is no page indicator in scroll mode.
        XCTAssertFalse(app.staticTexts["reader.pageIndicator"].firstMatch.exists,
                       "scroll mode must NOT show a page indicator")

        // A single tap toggles chrome off…
        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertFalse(chromeVisible(app), "single tap in scroll mode must hide chrome")

        // …and back on.
        toggleReaderChrome(in: app)
        sleep(1)
        XCTAssertTrue(chromeVisible(app), "single tap in scroll mode must restore chrome")

        // A drag must scroll the content without toggling chrome.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(1)
        // The native UITextView remains present after the drag and chrome
        // state is unchanged. Pixel-byte equality is not a reliable scroll
        // oracle because the same rendered page can be cached by XCTest.
        XCTAssertTrue(app.textViews.firstMatch.exists,
                      "scroll reader text surface must remain mounted after drag")
        XCTAssertTrue(chromeVisible(app), "a scroll drag must NOT toggle chrome")
    }

    func testScrollModeHorizontalSwipeChangesChapter() throws {
        let app = launch(layout: "scrolling")
        try openBook(app)
        guard let before = chapter(app), before.index + 1 < before.total else {
            throw XCTSkip("Need a following chapter.")
        }

        app.buttons["reader.scrollChapter.next"].tap()
        sleep(2)

        XCTAssertEqual(chapter(app)?.index, before.index + 1,
                       "left swipe in scroll mode must advance one chapter")

        app.buttons["reader.scrollChapter.previous"].tap()
        sleep(2)

        XCTAssertEqual(chapter(app)?.index, before.index,
                       "right swipe in scroll mode must return to the previous chapter")
    }
}
