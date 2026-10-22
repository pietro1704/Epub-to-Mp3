import XCTest

extension ReaderModesUITests {
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
        let slider = app.descendants(matching: .any)["reader.settings.margin"].firstMatch
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        let content = app.textViews["reader.content"].firstMatch
        XCTAssertTrue(marginRow.waitForExistence(timeout: 3), "Margin must remain a visible setting row.")
        XCTAssertTrue(slider.waitForExistence(timeout: 3), "Margin must use the native continuous slider.")
        for _ in 0..<8 where !slider.isHittable { app.tables.firstMatch.swipeUp() }
        XCTAssertTrue(slider.isHittable, "The margin slider must remain reachable in the compact settings sheet.")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Reader settings slider layout"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(viewport.exists && content.exists, "The open reader must remain mounted behind its settings sheet.")
        XCTAssertGreaterThanOrEqual(
            slider.frame.width,
            marginRow.frame.width - 40,
            "The slider must use the row's available width rather than sit in a narrow middle column."
        )

        dragReaderSlider(slider, to: 0)
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

        dragReaderSlider(slider, to: 0.5)
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

        dragReaderSlider(slider, to: 0)
        sleep(1)
        XCTAssertEqual(
            content.frame.minX,
            minimum.minX,
            accuracy: 1,
            "Returning the slider to its minimum must restore the 8 pt viewport immediately."
        )
    }
}
