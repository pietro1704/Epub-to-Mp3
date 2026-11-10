import XCTest

@MainActor
final class ReaderChapterPositionUITests: XCTestCase {
    func testExistingLOTRTOCPageDirectionsReaderReopenAndProcessRelaunch() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Keep books, audio and reading progress. Overrides are launch-only.
        app.launchArguments = ["-uiTestResetActiveReader", "-uiTestReaderLayout", "paginated",
            "-uiTestPaginationProbe", "-uiTestFlickerProbe", "-uiTestNoPageTurnOverlay",
            "-uiTestPageTurnStyle", "none", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let harness = ReaderModesHarness(app: app)
        try openBook(app)
        try selectChapter(containing: "long-expected", app: app)
        let firstChapter = chapter(app)
        XCTAssertNotNil(firstChapter)
        XCTAssertEqual(harness.paginationMetrics?.page, 1)
        try turn(forward: true, app: app, harness: harness)
        let pageTwo = try XCTUnwrap(harness.paginationMetrics)
        XCTAssertEqual(chapter(app), firstChapter, "The first page turn after TOC must keep its destination.")
        try turn(forward: true, app: app, harness: harness)
        try turn(forward: false, app: app, harness: harness)
        XCTAssertEqual(harness.paginationMetrics?.values["first"], pageTwo.values["first"])
        XCTAssertEqual(chapter(app), firstChapter)
        app.buttons["reader.close"].firstMatch.tap()
        try openBook(app)
        XCTAssertEqual(chapter(app), firstChapter)
        assertPosition(pageTwo.values, harness: harness)
        // Warm reopen and a fresh process exercise separate restoration paths.
        app.terminate()
        app.launchArguments.removeAll { $0 == "-uiTestResetActiveReader" }
        app.launch()
        try openBookIfNeeded(app)
        XCTAssertEqual(chapter(app), firstChapter)
        assertPosition(pageTwo.values, harness: harness)
        try turn(forward: true, app: app, harness: harness)
        try turn(forward: false, app: app, harness: harness)
        assertPosition(pageTwo.values, harness: harness)
        try selectChapter(containing: "shadow of the past", app: app)
        let secondChapter = chapter(app)
        XCTAssertNotEqual(secondChapter, firstChapter)
        XCTAssertEqual(harness.paginationMetrics?.page, 1)
        // No page turn before exiting: the TOC selection itself must be durable.
        app.terminate()
        app.launch()
        try openBookIfNeeded(app)
        XCTAssertEqual(chapter(app), secondChapter)
        XCTAssertEqual(harness.paginationMetrics?.page, 1)
        try turn(forward: true, app: app, harness: harness)
        XCTAssertEqual(chapter(app), secondChapter)
        try turn(forward: false, app: app, harness: harness)
        XCTAssertEqual(harness.paginationMetrics?.page, 1)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "LOTR-TOC-position-after-two-process-relaunches"
        capture.lifetime = .keepAlways
        add(capture)
    }

    private func openBook(_ app: XCUIApplication) throws {
        let expanded = app.buttons["fullPlayer.close"].firstMatch
        if expanded.waitForExistence(timeout: 1) { expanded.tap() }
        let tile = app.descendants(matching: .any)["library.bookTile.3e1c676b270dfa3fe555eba4d0cb9934"].firstMatch
        if !tile.waitForExistence(timeout: 1) {
            let search = app.searchFields["library.searchField"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            search.tap()
            search.typeText("lord")
        }
        guard tile.waitForExistence(timeout: 20) else {
            throw XCTSkip("Requires the retained local LOTR EPUB; the user's library is never replaced.")
        }
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        try waitForReader(app)
    }

    private func openBookIfNeeded(_ app: XCUIApplication) throws {
        if !app.buttons["reader.toc.toggle"].firstMatch.waitForExistence(timeout: 5) {
            try openBook(app)
        } else { try waitForReader(app) }
    }

    private func waitForReader(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.buttons["reader.toc.toggle"].firstMatch.waitForExistence(timeout: 60))
        let loaded = app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60)
        XCTAssertTrue(loaded, "Reader must finish loading: \(app.staticTexts.matching(identifier: "reader.paginationProbe").allElementsBoundByIndex.map(\.label))")
        XCTAssertTrue(wait {
            app.scrollViews.matching(identifier: "reader.viewport").allElementsBoundByIndex.contains(where: \.isHittable)
        }, "The reader must be visible before its position probes are accepted.")
        let harness = ReaderModesHarness(app: app)
        XCTAssertTrue(wait {
            guard let metrics = harness.paginationMetrics?.values else { return false }
            return (metrics["textFrameHeight"] ?? 0) > 0
                && metrics["textFrameHeight"] == metrics["measuredTextHeight"]
        }, "Reader geometry must be measured before navigation or restoration is asserted.")
    }

    private func chapter(_ app: XCUIApplication) -> Int? {
        app.staticTexts["flicker.probe.chapter"].firstMatch.label.split(separator: "/").first.flatMap { Int($0) }
    }

    private func selectChapter(containing title: String, app: XCUIApplication) throws {
        app.buttons["reader.toc.toggle"].firstMatch.tap()
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let target = table.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        for _ in 0..<15 {
            if target.exists && target.isHittable { break }
            table.swipeDown()
        }
        for _ in 0..<20 {
            if target.exists && target.isHittable { break }
            table.swipeUp()
        }
        XCTAssertTrue(target.exists && target.isHittable, "LOTR TOC must contain \(title).")
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)).tap()
        XCTAssertTrue(table.waitForNonExistence(timeout: 5))
        XCTAssertTrue(wait { ReaderModesHarness(app: app).paginationMetrics?.page == 1 })
    }

    private func turn(forward: Bool, app: XCUIApplication, harness: ReaderModesHarness) throws {
        let previous = try XCTUnwrap(harness.paginationMetrics?.page)
        let currentChapter = chapter(app)
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        viewport.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.95 : 0.05, dy: 0.5)).tap()
        XCTAssertTrue(wait { harness.paginationMetrics?.page == previous + (forward ? 1 : -1) })
        XCTAssertEqual(chapter(app), currentChapter)
        harness.assertNoClippedLines(scenario: "TOC and restored page navigation")
    }

    private func assertPosition(_ expected: [String: Int], harness: ReaderModesHarness) {
        let evidence = XCTAttachment(string: "expected=\(expected); actual=\(harness.paginationMetrics?.values ?? [:])")
        evidence.name = "reopened-reader-position"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertTrue(wait {
            harness.paginationMetrics?.page == expected["page"]
                && harness.paginationMetrics?.values["offset"] == expected["offset"]
        }, "The saved page and raw offset must both be restored: \(harness.paginationMetrics?.values ?? [:])")
        XCTAssertEqual(harness.paginationMetrics?.page, expected["page"],
                       "expected=\(expected); actual=\(harness.paginationMetrics?.values ?? [:])")
        XCTAssertEqual(harness.paginationMetrics?.values["offset"], expected["offset"])
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                      timeout: 15) == .completed
    }
}
