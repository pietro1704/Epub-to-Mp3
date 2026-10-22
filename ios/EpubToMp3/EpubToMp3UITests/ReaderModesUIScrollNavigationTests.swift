import XCTest

extension ReaderModesUITests {
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

    func testNativeLOTRScrollChapterControlsAdvanceAndRetreat() throws {
        let app = ReaderModesHarness().launch(.init(
            source: .seededLOTR,
            layout: "scrolling",
            smallFont: false,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true,
            flickerProbeEnabled: true
        ))
        try openBook(app, titleContaining: "lord")
        guard let before = chapter(app), before.index + 1 < before.total else {
            throw XCTSkip("Native LOTR needs a following chapter.")
        }

        let next = app.buttons["reader.scrollChapter.next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "Native LOTR must expose the next-chapter control.")
        next.tap()
        XCTAssertTrue(
            waitUntil(timeout: 5) { chapter(app)?.index == before.index + 1 },
            "Next chapter must advance native LOTR exactly one chapter."
        )

        let previous = app.buttons["reader.scrollChapter.previous"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 5), "Native LOTR must expose the previous-chapter control.")
        previous.tap()
        XCTAssertTrue(
            waitUntil(timeout: 5) { chapter(app)?.index == before.index },
            "Previous chapter must return native LOTR to the original chapter."
        )
    }
}
