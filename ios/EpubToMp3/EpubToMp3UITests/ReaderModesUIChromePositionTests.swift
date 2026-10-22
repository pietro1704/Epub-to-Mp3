import XCTest

extension ReaderModesUITests {
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
        let nativeBook = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile."))
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "lord"))
            .firstMatch
        XCTAssertTrue(nativeBook.waitForExistence(timeout: 20))
        XCTAssertTrue(nativeBook.label.localizedCaseInsensitiveContains("lord"),
                      "The regression must exercise the imported LOTR, not a fixture book.")
        try openBook(app, titleContaining: "lord")
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 30), "The native LOTR reader must open.")
        XCTAssertTrue(
            waitUntil(timeout: 60) {
                let metrics = self.paginationMetrics(app)
                return (metrics["first"] ?? -1) >= 0
                    && (metrics["total"] ?? 0) > 1
                    && (metrics["viewportHeight"] ?? 0) > 0
                    && self.chromeVisible(app)
            },
            "The native LOTR content must finish its real TextKit layout before reader gestures begin."
        )
        usleep(250_000)

        // The first substantive chapter can already begin past page four.
        // Test its real visible page rather than looping forever against an
        // accessibility snapshot that may lag the native page indicator.
        assertNoClippedPageLines(app, scenario: "native LOTR initial page before chrome toggling")
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
            XCTAssertTrue(
                chromeVisible(app),
                "native LOTR second center touch must restore chrome (metrics=\(paginationMetrics(app)))"
            )
            XCTAssertEqual(
                paginationMetrics(app)["first"], anchorBefore,
                "native LOTR round trip \(iteration) moved backward"
            )
            XCTAssertEqual(
                paginationMetrics(app)["offset"], offsetBefore,
                "native LOTR round trip \(iteration) changed the returned viewport offset (metrics=\(paginationMetrics(app)))"
            )
            assertNoClippedPageLines(app, scenario: "native LOTR round trip \(iteration)")
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
}
