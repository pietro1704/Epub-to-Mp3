import XCTest

@MainActor
final class ReaderPagePlaybackChoiceUITests: XCTestCase {
    func testOptInActualReaderPageChoicesThroughPlayPause() throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_LIVE_EDGE"] == "1",
              let bookID = ProcessInfo.processInfo.environment["EPUB2MP3_GUI_BOOK_ID"],
              !bookID.isEmpty, !bookID.hasPrefix("$(") else {
            throw XCTSkip("Stage the dedicated real EPUB and enable live Edge verification.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-developmentSeedBook", "-uiTestResetActiveReader", "-uiTestResetReaderPosition", "-uiTestReaderLayout", "paginated",
                               "-uiTestPaginationProbe", "-uiTestNoPageTurnOverlay",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "reader-page-playback-final"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let closePlayer = app.buttons["fullPlayer.close"].firstMatch
        if closePlayer.waitForExistence(timeout: 2), closePlayer.isHittable { closePlayer.tap() }
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].waitForNonExistence(timeout: 60))
        let harness = ReaderModesHarness(app: app)
        XCTAssertTrue(wait(timeout: 20) { (harness.paginationMetrics?.values["total"] ?? 0) > 1 })
        let mini = app.buttons["miniPlayer.playPause"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.tap()
        XCTAssertTrue(wait(timeout: 15) { mini.label == "Pause" })
        mini.tap()
        XCTAssertTrue(wait(timeout: 5) { mini.label == "Play" })
        try turnPage(in: app, harness: harness, forward: true)
        mini.tap()
        let currentPage = app.sheets.buttons["Listen from this page"].firstMatch
        XCTAssertTrue(currentPage.waitForExistence(timeout: 5), "Paused Play must offer the newly visible page.")
        XCTAssertTrue(app.sheets.buttons["Continue where I left off"].firstMatch.exists)
        currentPage.tap()
        app.buttons["miniPlayer.open"].firstMatch.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(timeout: 15) { self.seconds(elapsed.label) > 10 })
        XCTAssertTrue(app.staticTexts["Device streaming chapter one"].firstMatch.exists,
                      "The last reader page must seek within its chapter, not skip to the next chapter.")
        let selectedPosition = seconds(elapsed.label)
        app.buttons["Pause"].firstMatch.tap()
        closePlayer.tap()
        try turnPage(in: app, harness: harness, forward: false)
        mini.tap()
        let continuation = app.sheets.buttons["Continue where I left off"].firstMatch
        XCTAssertTrue(continuation.waitForExistence(timeout: 5))
        continuation.tap()
        app.buttons["miniPlayer.open"].firstMatch.tap()
        XCTAssertTrue(wait(timeout: 5) { self.seconds(elapsed.label) >= selectedPosition - 1 })
        XCTAssertLessThan(seconds(elapsed.label), selectedPosition + 10,
                          "Continue must retain the audio cursor instead of restarting at the reader's first page.")
        closePlayer.tap()
        XCTAssertFalse(app.buttons["reader.playCurrentPage"].exists)
        try turnPage(in: app, harness: harness, forward: true)
        XCTAssertEqual(mini.label, "Pause")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Turning a page must not interrupt audio.")
        mini.tap()
        XCTAssertEqual(mini.label, "Play")
        mini.tap()
        XCTAssertTrue(currentPage.waitForExistence(timeout: 5))
        XCTAssertEqual(app.sheets.buttons.count, 3)
        XCTAssertGreaterThanOrEqual(mini.frame.width, 44)
        XCTAssertGreaterThanOrEqual(mini.frame.height, 44)
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertGreaterThanOrEqual(cancel.frame.height, 44)
        cancel.tap()
        XCTAssertEqual(mini.label, "Play", "Cancel must leave the audio paused.")
        mini.tap()
        XCTAssertTrue(currentPage.waitForExistence(timeout: 5))
        currentPage.tap()
        app.buttons["miniPlayer.open"].firstMatch.tap()
        XCTAssertTrue(wait(timeout: 10) { self.seconds(elapsed.label) > 10 })
        XCTAssertTrue(app.buttons["Pause"].firstMatch.exists)
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["Play"].firstMatch.tap()
        XCTAssertFalse(currentPage.exists, "Without another page turn, ordinary pause/resume must not ask again.")
        XCTAssertTrue(app.buttons["Pause"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Pause"].firstMatch.tap()
        closePlayer.tap()
        harness.assertNoClippedLines(scenario: "Page playback controls preserve reader geometry")
    }

    func testOptInPortuguesePageChoicesFitSE() throws {
        guard ProcessInfo.processInfo.environment["APP_IOS_LIVE_EDGE"] == "1",
              let bookID = ProcessInfo.processInfo.environment["EPUB2MP3_GUI_BOOK_ID"],
              !bookID.isEmpty, !bookID.hasPrefix("$(") else {
            throw XCTSkip("Stage the dedicated real EPUB and enable live Edge verification.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-developmentSeedBook", "-uiTestResetActiveReader", "-uiTestResetReaderPosition",
                               "-uiTestReaderLayout", "paginated", "-uiTestPaginationProbe", "-uiTestNoPageTurnOverlay",
                               "-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt_BR"]
        app.launch()
        let closePlayer = app.buttons["fullPlayer.close"].firstMatch
        if closePlayer.waitForExistence(timeout: 2), closePlayer.isHittable { closePlayer.tap() }
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 20))
        tile.tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].waitForNonExistence(timeout: 60))
        let harness = ReaderModesHarness(app: app)
        XCTAssertTrue(wait(timeout: 20) { (harness.paginationMetrics?.values["total"] ?? 0) > 1 })
        let mini = app.buttons["miniPlayer.playPause"].firstMatch
        XCTAssertTrue(mini.waitForExistence(timeout: 10))
        mini.tap()
        XCTAssertTrue(wait(timeout: 15) { mini.label == "Pausar" })
        mini.tap()
        XCTAssertTrue(wait(timeout: 5) { mini.label == "Reproduzir" })
        try turnPage(in: app, harness: harness, forward: true)
        mini.tap()
        let continuation = app.sheets.buttons["Continuar de onde parei"].firstMatch
        let page = app.sheets.buttons["Ouvir a partir desta página"].firstMatch
        XCTAssertTrue(continuation.waitForExistence(timeout: 5))
        XCTAssertTrue(page.exists)
        XCTAssertEqual(app.sheets.buttons.count, 3)
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertEqual(windowFrame.width, 320, accuracy: 1)
        for action in [continuation, page] {
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            XCTAssertGreaterThanOrEqual(action.frame.minX, windowFrame.minX)
            XCTAssertLessThanOrEqual(action.frame.maxX, windowFrame.maxX)
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "reader-page-playback-portuguese-SE-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.sheets.buttons["Cancelar"].firstMatch.tap()
        XCTAssertTrue(wait(timeout: 5) { mini.label == "Reproduzir" })
        XCTAssertFalse(app.sheets.firstMatch.exists)
        XCTAssertFalse(app.buttons["reader.playCurrentPage"].exists)
    }

    private func turnPage(in app: XCUIApplication, harness: ReaderModesHarness, forward: Bool) throws {
        let before = try XCTUnwrap(harness.paginationMetrics?.values["page"])
        let viewports = app.scrollViews.matching(identifier: "reader.viewport")
        let viewport = viewports.allElementsBoundByIndex.first(where: \.isHittable) ?? viewports.firstMatch
        XCTAssertTrue(viewport.exists)
        let rect = viewport.frame.intersection(app.windows.firstMatch.frame)
        XCTAssertGreaterThan(rect.height, 100)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: rect.minX + rect.width * (forward ? 0.8 : 0.2), dy: rect.maxY - 24))
        let end = origin.withOffset(CGVector(dx: rect.minX + rect.width * (forward ? 0.2 : 0.8), dy: rect.maxY - 24))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(wait(timeout: 5) { harness.paginationMetrics?.values["page"] == before + (forward ? 1 : -1) },
                      "An actual swipe must change the page: before=\(before), viewport=\(rect), metrics=\(harness.paginationMetrics?.values ?? [:])")
    }

    private func wait(timeout: TimeInterval, predicate: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)],
                      timeout: timeout) == .completed
    }

    private func seconds(_ label: String) -> Int {
        let parts = label.split(separator: ":").compactMap { Int($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
