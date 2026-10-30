import XCTest

@MainActor
final class PhysicalDeviceDownloadUITests: XCTestCase {
    func testOptInAuthoredDownloadSurvivesRelaunchAndScopedRemoval() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_DOWNLOAD_MATRIX"] == "1" else {
            throw XCTSkip("Requires the installed authored Portuguese EPUB and authorized test-download removal.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let bookID = "7c135a6d930d789aaadede9a02cdc8aa"
        openAuthoredBook(app, bookID: bookID)
        let miniPlay = app.buttons["miniPlayer.playPause"].firstMatch
        if miniPlay.label.lowercased() == "play" { miniPlay.tap() }
        let open = app.buttons["miniPlayer.open"].firstMatch
        open.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        let transport = app.buttons["fullPlayer.playPause"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 90))
        XCTAssertTrue(wait(timeout: 120) { self.seconds(elapsed.label) > 1 })
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Faber")).firstMatch.exists)
        XCTAssertTrue(wait(timeout: 150) { self.seconds(elapsed.label) >= 50 }, "The authored 57-second chapter must advance beyond its early segments.")
        XCTAssertTrue(wait(timeout: 90) { transport.label.lowercased() == "play" }, "The one-chapter fixture must reach its natural end.")
        XCTAssertGreaterThanOrEqual(seconds(elapsed.label), 50)
        capture("authored-chapter-natural-end")
        app.buttons["fullPlayer.close"].tap()
        app.buttons["reader.toc.toggle"].tap()
        let download = app.buttons["reader.toc.download.0"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(timeout: 90) { download.isEnabled })
        if (download.value as? String)?.lowercased() != "downloaded" { download.tap() }
        XCTAssertTrue(wait(timeout: 30) { (download.value as? String)?.lowercased() == "downloaded" })
        capture("authored-chapter-retained-download")
        app.buttons["Close"].firstMatch.tap()
        app.terminate()
        app.launch()
        openAuthoredBook(app, bookID: bookID)
        app.buttons["reader.toc.toggle"].tap()
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        XCTAssertEqual((download.value as? String)?.lowercased(), "downloaded")
        app.buttons["Close"].firstMatch.tap()
        open.tap()
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        if transport.label.lowercased() == "pause" { transport.tap() }
        app.buttons["fullPlayer.skipBack"].tap()
        transport.tap()
        let before = seconds(elapsed.label)
        XCTAssertTrue(wait(timeout: 30) { self.seconds(elapsed.label) > before + 1 })
        transport.tap()
        capture("authored-retained-playback-after-relaunch")
        app.buttons["fullPlayer.close"].tap()
        app.buttons["reader.close"].tap()
        app.tabBars.buttons["Settings"].tap()
        let manage = app.cells["settings.manageDownloads"].firstMatch
        let settings = app.tables.firstMatch
        for _ in 0..<24 {
            if manage.exists && manage.isHittable && manage.frame.maxY < open.frame.minY { break }
            settings.swipeUp()
        }
        XCTAssertTrue(manage.isHittable)
        manage.tap()
        let row = app.cells["settings.downloadedBook.\(bookID)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        XCTAssertTrue(row.staticTexts["Piper Live Portuguese"].exists, "Removal is restricted to the authored acceptance fixture.")
        let otherDownloads = app.cells.allElementsBoundByIndex.map(\.identifier)
            .filter { $0.hasPrefix("settings.downloadedBook.") && $0 != row.identifier }
        capture("authored-download-listed")
        row.tap()
        let confirmation = app.alerts["Remove downloaded audio?"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Piper Live Portuguese")).firstMatch.exists)
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)
        capture("authored-download-removal-cancelled")
        row.tap()
        confirmation.buttons["Remove download"].tap()
        XCTAssertTrue(wait(timeout: 60) { !row.exists }, app.debugDescription)
        for identifier in otherDownloads {
            XCTAssertTrue(app.cells[identifier].exists, "Other books' downloads must remain listed.")
        }
        capture("authored-download-removed")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch.waitForExistence(timeout: 10),
                      "Removing downloaded audio must preserve the imported source book.")
    }

    private func openAuthoredBook(_ app: XCUIApplication, bookID: String) {
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.waitForExistence(timeout: 2) { close.tap() }
        app.tabBars.buttons["Library"].tap()
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        let books = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if tile.frame.intersection(books.frame).height >= 80 { break }
            books.swipeUp()
        }
        let visible = tile.frame.intersection(books.frame)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: visible.minY + 30)).tap()
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
    }

    private func wait(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let predicate = NSPredicate { _, _ in condition() }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout) == .completed
    }

    private func seconds(_ label: String) -> Int {
        label.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
