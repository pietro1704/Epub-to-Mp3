import XCTest

@MainActor
final class RealBookReaderUITests: XCTestCase {
    func testActualLOTRReaderPaginationAndChrome() throws {
        try verifyReader(bookID: "3e1c676b270dfa3fe555eba4d0cb9934")
    }

    func testActualLOTRSmallTextPaginationAndChrome() throws {
        try verifyReader(bookID: "3e1c676b270dfa3fe555eba4d0cb9934", smallText: true)
    }

    func testActualChristieReaderPaginationAndChrome() throws {
        try verifyReader(bookID: "55417053355de78768a0823d3cd203fd")
    }

    func testOptInExistingLOTRPageStylesAndChrome() throws {
        try verifyExistingLOTRStyles(smallText: false)
    }

    func testOptInExistingLOTRSmallTextPageStylesAndChrome() throws {
        try verifyExistingLOTRStyles(smallText: true)
    }

    func testOptInAuthoredBookSearchResultsAndCancellation() throws {
        let app = try openAuthoredLinkBook()
        defer { app.terminate() }
        let harness = ReaderModesHarness(app: app)
        submitLiveSearch("ORIGIN7964", app: app)
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["flicker.probe.chapter"].label == "0/2" })
        let before = try XCTUnwrap(harness.paginationMetrics)
        submitLiveSearch("absent-verification-7964", app: app)
        XCTAssertTrue(app.alerts.staticTexts["No matches found"].waitForExistence(timeout: 15))
        app.alerts.buttons["OK"].firstMatch.tap()
        XCTAssertEqual(harness.paginationMetrics?.values["offset"], before.values["offset"])
        app.buttons["reader.search"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("DESTINATION7964")
        app.alerts.buttons["Cancel"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertEqual(harness.paginationMetrics?.values["offset"], before.values["offset"])
        submitLiveSearch("DESTINATION7964", app: app)
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["flicker.probe.chapter"].label == "1/2" })
        XCTAssertTrue(app.staticTexts["flicker.probe.chapter"].label.hasPrefix("1/"))
        harness.assertNoClippedLines(scenario: "Search reveals the destination chapter")
        submitLiveSearch("ORIGIN7964", app: app)
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["flicker.probe.chapter"].label == "0/2" })
        XCTAssertTrue(app.staticTexts["flicker.probe.chapter"].label.hasPrefix("0/"))
        retainLiveCapture(app, name: "authored-search-origin-restored")
    }

    func testOptInAuthoredBookLinkPreviewAndNavigation() throws {
        let app = try openAuthoredLinkBook()
        defer { app.terminate() }
        submitLiveSearch("ORIGIN7964", app: app)
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["flicker.probe.chapter"].label == "0/2" })
        let harness = ReaderModesHarness(app: app)
        let before = try XCTUnwrap(harness.paginationMetrics)
        for (label, expected) in [("Short note", "SHORTNOTE7964"), ("Long note", "LONGNOTE7964")] {
            let link = app.links[label].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 5))
            link.tap()
            let preview = app.textViews["reader.linkPreview.text"].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            XCTAssertTrue((preview.value as? String ?? "").contains(expected))
            if label == "Long note" {
                for _ in 0..<8 { preview.swipeUp() }
                retainLiveCapture(app, name: "authored-long-note-scrolled")
            }
            app.navigationBars.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
            XCTAssertEqual(harness.paginationMetrics?.values["offset"], before.values["offset"])
            XCTAssertTrue(app.staticTexts["flicker.probe.chapter"].label.hasPrefix("0/"))
        }
        app.links["Missing destination"].firstMatch.tap()
        XCTAssertTrue(app.alerts.staticTexts["This destination is unavailable in the book."].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].firstMatch.tap()
        XCTAssertEqual(harness.paginationMetrics?.values["offset"], before.values["offset"])
        app.links["Internal destination"].firstMatch.tap()
        let navigate = app.buttons["reader.linkPreview.goToPosition"].firstMatch
        XCTAssertTrue(navigate.waitForExistence(timeout: 5))
        navigate.tap()
        XCTAssertTrue(waitUntil(timeout: 15) { app.staticTexts["flicker.probe.chapter"].label == "1/2" })
        XCTAssertTrue(app.staticTexts["flicker.probe.chapter"].label.hasPrefix("1/"))
        harness.assertNoClippedLines(scenario: "Explicit internal-link navigation")
        retainLiveCapture(app, name: "authored-link-destination")
    }

    func testOptInAuthoredBookScrollingAndChapterRoundTrip() throws {
        let app = try openAuthoredLinkBook(layout: "scrolling")
        defer { app.terminate() }
        submitLiveSearch("ORIGIN7964", app: app)
        let chapter = app.staticTexts["flicker.probe.chapter"].firstMatch
        XCTAssertTrue(waitUntil(timeout: 15) { chapter.label == "0/2" })
        XCTAssertFalse(app.staticTexts["reader.pageIndicator"].firstMatch.exists)
        let offsetProbe = app.staticTexts["reader.scrollOffset"].firstMatch
        func offset() -> Int? { offsetProbe.label.split(separator: "=").last.flatMap { Int($0) } }
        let initialOffset = try XCTUnwrap(offset())
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            .press(forDuration: 0.1, thenDragTo: viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        XCTAssertTrue(waitUntil(timeout: 5) { (offset() ?? initialOffset) > initialOffset + 50 })
        XCTAssertTrue(app.buttons["reader.search"].isHittable, "Scrolling must preserve visible chrome.")
        let harness = ReaderModesHarness(app: app)
        let settledOffset = try XCTUnwrap(offset())
        harness.toggleChromeAndSettle(visible: false)
        XCTAssertEqual(offset(), settledOffset, "Hiding chrome must preserve the raw scrolling offset.")
        retainLiveCapture(app, name: "authored-scrolling-hidden-chrome")
        harness.toggleChromeAndSettle(visible: true)
        XCTAssertEqual(offset(), settledOffset, "The chrome round trip must preserve the raw scrolling offset.")
        viewport.swipeLeft()
        XCTAssertTrue(waitUntil(timeout: 10) { chapter.label == "1/2" })
        viewport.swipeLeft()
        XCTAssertEqual(chapter.label, "1/2", "The final chapter must reject navigation beyond the book.")
        viewport.swipeRight()
        XCTAssertTrue(waitUntil(timeout: 10) { chapter.label == "0/2" })
        viewport.swipeRight()
        XCTAssertEqual(chapter.label, "0/2", "The first chapter must reject navigation before the book.")
        retainLiveCapture(app, name: "authored-scrolling-chapter-restored")
    }

    // Install Fixtures/ReaderLiveLinks.epub explicitly, then pass its imported book ID.
    private func openAuthoredLinkBook(layout: String = "paginated") throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_READER_LINKS"] == "1",
              let bookID = ProcessInfo.processInfo.environment["APP_DEVICE_LINK_BOOK_ID"] else {
            throw XCTSkip("Requires the explicitly installed authored live acceptance EPUB.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-uiTestReaderLayout", layout,
            "-uiTestPaginationProbe", "-uiTestFlickerProbe", "-uiTestNoPageTurnOverlay", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        return app
    }

    private func submitLiveSearch(_ query: String, app: XCUIApplication) {
        app.buttons["reader.search"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(query)
        app.alerts.buttons["OK"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }

    private func retainLiveCapture(_ app: XCUIApplication, name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = name
        capture.lifetime = .keepAlways
        add(capture)
    }

    private func verifyExistingLOTRStyles(smallText: Bool) throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_READER_MATRIX"] == "1" else {
            throw XCTSkip("Requires the authorized physical-device existing-book journey.")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let bookID = "3e1c676b270dfa3fe555eba4d0cb9934"
        for style in ["flip", "slide", "none"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTestResetActiveReader", "-uiTestReaderLayout", "paginated",
                "-uiTestChromeToggle", "-uiTestPaginationProbe", "-uiTestFlickerProbe", "-uiTestNoPageTurnOverlay",
                "-uiTestPageTurnStyle", style, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            if smallText { app.launchArguments += ["-uiTestReaderFontSize", "0", "-uiTestReaderOverrideFontSize"] }
            app.launch()
            defer { app.terminate() }
            let expanded = app.buttons["fullPlayer.close"].firstMatch
            if expanded.waitForExistence(timeout: 2) { expanded.tap() }
            let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 30))
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            XCTAssertTrue(app.buttons["reader.search"].firstMatch.waitForExistence(timeout: 60))
            XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
            let harness = ReaderModesHarness(app: app)
            XCTAssertTrue(waitUntil(timeout: 30) {
                (harness.paginationMetrics?.values["total"] ?? 0) > 1
            })
            harness.toggleChromeAndSettle(visible: true)
            let initial = try XCTUnwrap(harness.paginationMetrics)
            let initialPage = try XCTUnwrap(initial.page)
            let total = try XCTUnwrap(initial.total)
            let forward = initialPage + 1 < total
            try swipeExistingPage(app, harness: harness, forward: forward)
            for visible in [true, false] {
                harness.toggleChromeAndSettle(visible: visible)
                let before = try XCTUnwrap(harness.paginationMetrics)
                harness.assertNoClippedLines(scenario: "\(style) visible=\(visible) small=\(smallText)")
                try swipeExistingPage(app, harness: harness, forward: !forward)
                try swipeExistingPage(app, harness: harness, forward: forward)
                XCTAssertEqual(harness.paginationMetrics?.page, before.page)
                let capture = XCTAttachment(screenshot: app.screenshot())
                capture.name = "existing-LOTR-\(style)-chrome-\(visible)-small-\(smallText)"
                capture.lifetime = .keepAlways
                add(capture)
            }
            harness.toggleChromeAndSettle(visible: true)
            let beforeToggle = try XCTUnwrap(harness.paginationMetrics)
            for _ in 0..<3 {
                harness.toggleChromeAndSettle(visible: false)
                harness.assertNoClippedLines(scenario: "Repeated hidden chrome")
                harness.toggleChromeAndSettle(visible: true)
                XCTAssertEqual(harness.paginationMetrics?.values["offset"], beforeToggle.values["offset"])
                XCTAssertEqual(harness.paginationMetrics?.values["first"], beforeToggle.values["first"])
            }
            try swipeExistingPage(app, harness: harness, forward: !forward)
            XCTAssertEqual(harness.paginationMetrics?.page, initial.page)
            harness.assertNoClippedLines(scenario: "Return to initial reading page")
            app.terminate()
        }
    }

    private func swipeExistingPage(_ app: XCUIApplication, harness: ReaderModesHarness, forward: Bool) throws {
        let before = try XCTUnwrap(harness.paginationMetrics)
        let previous = try XCTUnwrap(before.page)
        let total = try XCTUnwrap(before.total)
        let chapterProbe = app.staticTexts["flicker.probe.chapter"].firstMatch
        func chapter() -> Int? { chapterProbe.label.split(separator: "/").first.flatMap { Int($0) } }
        let originalChapter = try XCTUnwrap(chapter())
        let crossesChapter = forward ? previous >= total : previous <= 1
        let expectedChapter = originalChapter + (crossesChapter ? (forward ? 1 : -1) : 0)
        let viewport = try XCTUnwrap(app.scrollViews.matching(identifier: "reader.viewport")
            .allElementsBoundByIndex.first(where: \.isHittable))
        let visible = viewport.frame.intersection(app.windows.firstMatch.frame)
        XCTAssertGreaterThan(visible.height, 100)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: visible.minX + visible.width * (forward ? 0.8 : 0.2), dy: visible.maxY - 24))
        let end = origin.withOffset(CGVector(dx: visible.minX + visible.width * (forward ? 0.2 : 0.8), dy: visible.maxY - 24))
        start.press(forDuration: 0.1, thenDragTo: end)
        let moved = waitUntil(timeout: 5) {
            guard chapter() == expectedChapter, let current = harness.paginationMetrics else { return false }
            if crossesChapter { return forward ? current.page == 1 : current.page == current.total }
            return current.page == previous + (forward ? 1 : -1)
        }
        let evidence = XCTAttachment(string: "chapter=\(originalChapter)->\(chapter() ?? -1); forward=\(forward); viewport=\(visible); before=\(before.values); after=\(harness.paginationMetrics?.values ?? [:])")
        evidence.name = "actual-page-swipe-metrics"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertTrue(moved, "forward=\(forward); before=\(before.values); after=\(harness.paginationMetrics?.values ?? [:])")
        harness.assertNoClippedLines(scenario: "Production swipe with visible or hidden chrome")
    }

    private func verifyReader(bookID: String, smallText: Bool = false) throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        // Actual imported EPUBs only: never replace content or audio with UI fixtures.
        app.launchArguments = ["-developmentSeedBook", "-uiTestResetReaderPosition",
            "-uiTestReaderLayout", "paginated", "-uiTestChromeToggle",
            "-uiTestPaginationProbe", "-uiTestNoPageTurnOverlay", "-uiTestResetActiveReader"]
        if smallText {
            app.launchArguments += ["-uiTestReaderFontSize", "0", "-uiTestReaderOverrideFontSize"]
        }
        app.launch()
        let expandedClose = app.buttons["fullPlayer.close"].firstMatch
        if expandedClose.waitForExistence(timeout: 2), expandedClose.isHittable {
            expandedClose.tap()
        }
        let harness = ReaderModesHarness(app: app)
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "The hash-verified real book must be imported.")
        // Start on the library surface, then open exactly one real reader.
        // The development seed can otherwise leave the same book mounted in
        // MainReaderScreenController while the library presents a second one.
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].waitForNonExistence(timeout: 60),
                      "Reader navigation is intentionally blocked until loading finishes.")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let metrics = harness.paginationMetrics, (metrics.values["first"] ?? -1) >= 0,
               (metrics.values["total"] ?? 0) > 1 { break }
            usleep(100_000)
        }
        let initial = try XCTUnwrap(harness.paginationMetrics)
        XCTAssertGreaterThan(initial.values["total"] ?? 0, 1)
        harness.assertNoClippedLines(scenario: "\(bookID) initial actual EPUB")
        try turnPage(in: app, harness: harness, forward: true)
        harness.assertNoClippedLines(scenario: "\(bookID) next page")
        let advanced = try XCTUnwrap(harness.paginationMetrics)
        for _ in 0..<2 {
            harness.toggleChromeAndSettle(visible: false)
            harness.assertNoClippedLines(scenario: "\(bookID) hidden chrome")
            harness.toggleChromeAndSettle(visible: true)
            let restored = try XCTUnwrap(harness.paginationMetrics)
            XCTAssertEqual(restored.values["offset"], advanced.values["offset"])
            XCTAssertEqual(restored.values["first"], advanced.values["first"])
            harness.assertNoClippedLines(scenario: "\(bookID) restored chrome")
        }
        try turnPage(in: app, harness: harness, forward: false)
        harness.assertNoClippedLines(scenario: "\(bookID) previous page")
        let attachment = XCTAttachment(string: "bookID=\(bookID); initial=\(initial.values); advanced=\(advanced.values)")
        attachment.name = "actual-book-pagination-evidence"
        attachment.lifetime = .keepAlways
        add(attachment)
        let beforePlayer = try XCTUnwrap(harness.paginationMetrics)
        let openPlayer = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(openPlayer.waitForExistence(timeout: 5))
        openPlayer.tap()
        XCTAssertTrue(app.staticTexts["fullPlayer.bookTitle"].waitForExistence(timeout: 5))
        let playerScreenshot = XCTAttachment(screenshot: app.screenshot())
        playerScreenshot.name = "actual-book-expanded-player"
        playerScreenshot.lifetime = .keepAlways
        add(playerScreenshot)
        let closePlayer = app.buttons["fullPlayer.close"].firstMatch
        XCTAssertTrue(closePlayer.isHittable)
        closePlayer.tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 5))
        let afterPlayer = try XCTUnwrap(harness.paginationMetrics)
        XCTAssertEqual(afterPlayer.values["offset"], beforePlayer.values["offset"])
        harness.assertNoClippedLines(scenario: "expanded player dismissal")
    }

    private func turnPage(in app: XCUIApplication, harness: ReaderModesHarness, forward: Bool) throws {
        let previous = try XCTUnwrap(harness.paginationMetrics?.values["page"])
        let pageCount = try XCTUnwrap(harness.paginationMetrics?.values["total"])
        let indicators = app.descendants(matching: .any)
            .matching(identifier: "reader.pageIndicator")
        let pageIndicator = indicators.allElementsBoundByIndex.first { element in
            let value = (element.value as? String) ?? element.label
            return element.isHittable && value.contains("\(pageCount)")
        }
        XCTAssertNotNil(pageIndicator, "The active reader page indicator must be visible and exposed.")
        let activeIndicator = try XCTUnwrap(pageIndicator)
        let previousIndicator = activeIndicator.value as? String
        let viewports = app.scrollViews.matching(identifier: "reader.viewport")
        let viewport = try XCTUnwrap(viewports.allElementsBoundByIndex.first(where: \.isHittable))
        XCTAssertTrue(viewport.exists)
        // Exercise production swipe handling, not test-only invisible overlay buttons.
        let visible = viewport.frame.intersection(app.windows.firstMatch.frame)
        XCTAssertGreaterThan(visible.height, 100)
        let geometry = XCTAttachment(string: "viewport=\(viewport.frame); window=\(app.windows.firstMatch.frame); visible=\(visible)")
        geometry.name = "actual-swipe-screen-geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let y = visible.maxY - 24
        let start = origin.withOffset(CGVector(dx: visible.minX + visible.width * (forward ? 0.8 : 0.2), dy: y))
        let end = origin.withOffset(CGVector(dx: visible.minX + visible.width * (forward ? 0.2 : 0.8), dy: y))
        start.press(forDuration: 0.1, thenDragTo: end)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = harness.paginationMetrics?.values["page"]
            let currentIndicator = activeIndicator.value as? String
            let expectedPage = previous + (forward ? 1 : -1)
            if current == expectedPage, currentIndicator != previousIndicator {
                return
            }
            usleep(100_000)
        }
        let probe = harness.paginationProbe(for: pageCount)
        let accessibility = indicators.allElementsBoundByIndex.map {
            "frame=\($0.frame), hittable=\($0.isHittable), label=\($0.label), value=\(String(describing: $0.value))"
        }.joined(separator: " | ")
        let probes = app.staticTexts.matching(identifier: "reader.paginationProbe").allElementsBoundByIndex.map {
            "frame=\($0.frame), hittable=\($0.isHittable), label=\($0.label)"
        }.joined(separator: " | ")
        XCTFail("An actual horizontal swipe must change the page; indicator=\(String(describing: activeIndicator.value)); probe=\(probe?.label ?? "missing"); metrics=\(harness.paginationMetrics?.values ?? [:]); indicators=\(accessibility); probes=\(probes)")
    }
}
