import XCTest

/// Exercises only the already imported Manual de Campo; never replaces its source.
@MainActor
final class PDFReaderParityUITests: XCTestCase {
    func testManualPDFHasAppAudioMenuHorizontalPagesScrollAndRestoration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestReduceMotion", "-uiTestReaderLayout", "paginated", "-uiTestReaderShowPageNumbers"]
        app.launch()
        defer { app.terminate() }
        let playerClose = app.buttons["fullPlayer.close"].firstMatch
        if playerClose.waitForExistence(timeout: 2) { playerClose.tap() }
        openManual(app)
        let pdf = app.descendants(matching: .any)["reader.pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["reader.more"].firstMatch.exists)
        XCTAssertFalse(app.buttons["reader.playFromHere"].exists, "The reader bar keeps exactly two actions")
        let indicator = app.staticTexts["reader.pageIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 10))
        let original = (indicator.value as? String ?? "")
        pdf.swipeLeft()
        XCTAssertTrue(wait { (indicator.value as? String ?? "") != original })
        pdf.swipeRight()
        XCTAssertTrue(wait { (indicator.value as? String ?? "") == original })
        pdf.press(forDuration: 0.8)
        let menu = app.sheets.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.buttons["Play from here"].exists)
        XCTAssertFalse(menu.buttons["Copy"].exists)
        XCTAssertFalse(app.menuItems["Copy"].exists)
        let beforeDismiss = XCTAttachment(string: "\(pdf.value ?? "")\n\(app.debugDescription)")
        beforeDismiss.name = "pdf-menu-before-dismiss"
        beforeDismiss.lifetime = .keepAlways
        add(beforeDismiss)
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists && cancel.isHittable { cancel.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.25)).tap() }
        let dismissed = menu.waitForNonExistence(timeout: 5)
        let afterDismiss = XCTAttachment(string: "\(pdf.value ?? "")\n\(app.debugDescription)")
        afterDismiss.name = "pdf-menu-after-dismiss"
        afterDismiss.lifetime = .keepAlways
        add(afterDismiss)
        XCTAssertTrue(dismissed)
        XCTAssertEqual(app.menuItems.count, 0, "PDF reading must not expose native editing or Writing Tools menus")
        XCTAssertEqual(indicator.value as? String, original, "Dismissing the PDF action must preserve the page")
        XCTAssertEqual(app.buttons["miniPlayer.playPause"].label, "Play", "Cancelling must not start playback")
        attach("manual-pdf-paginated-app-controls", app: app)
        app.terminate()
        app.launchArguments[app.launchArguments.firstIndex(of: "paginated")!] = "scrolling"
        app.launch()
        openManual(app)
        // Hold at the end of each drag so the saved page is measured after
        // scrolling stops, rather than during a swipe's deceleration.
        let scrollStart = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let scrollEnd = pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        for _ in 0..<2 {
            scrollStart.press(forDuration: 0.05, thenDragTo: scrollEnd,
                              withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let scrolled = (indicator.value as? String ?? "")
        XCTAssertFalse(scrolled.isEmpty)
        attach("manual-pdf-scroll", app: app)
        app.buttons["reader.close"].firstMatch.tap()
        openManual(app)
        XCTAssertTrue(wait { (indicator.value as? String ?? "") == scrolled },
                      "Expected \(scrolled), reopened at \(indicator.value ?? "")")
        app.terminate()
        app.launchArguments[app.launchArguments.firstIndex(of: "scrolling")!] = "paginated"
        app.launch()
        openManual(app)
        XCTAssertTrue(wait { (indicator.value as? String ?? "") == scrolled },
                      "Expected \(scrolled), relaunched at \(indicator.value ?? "")")
        attach("manual-pdf-restored-page", app: app)
        let page = ((indicator.value as? String) ?? "").split(separator: " ").first.map(String.init) ?? ""
        activateListenTool(app)
        let miniTransport = app.buttons["miniPlayer.playPause"]
        XCTAssertTrue(wait(timeout: 90) {
            let compatible = app.alerts.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Use Faber")).firstMatch
            if compatible.exists { compatible.tap() }
            return miniTransport.exists && miniTransport.label == "Pause"
        }, "Play from here must produce playable audio for this book")
        let openPlayer = app.buttons["miniPlayer.open"]
        XCTAssertTrue((openPlayer.value as? String ?? "").contains("Page \(page)"),
                      "The audio chapter must match the visible PDF page")
        openPlayer.tap()
        let transport = app.buttons["fullPlayer.playPause"]
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        let elapsed = app.staticTexts["fullPlayer.elapsed"]
        let initialTime = elapsed.label
        XCTAssertTrue(wait { elapsed.label != initialTime })
        attach("manual-pdf-playing-from-visible-page", app: app)
        transport.tap()
        XCTAssertTrue(wait { transport.label == "Play" })
        Thread.sleep(forTimeInterval: 0.5)
        let pausedTime = elapsed.label
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(elapsed.label, pausedTime)
        transport.tap()
        XCTAssertTrue(wait { transport.label == "Pause" })
        XCTAssertTrue(wait { elapsed.label != pausedTime })
        transport.tap()
        XCTAssertTrue(wait { transport.label == "Play" })
        app.buttons["fullPlayer.close"].tap()

    }

    private func openManual(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Library"]
        XCTAssertTrue(tab.waitForExistence(timeout: 15))
        tab.tap()
        let tile = app.descendants(matching: .any)["library.bookTile.ecef90821c846919621d786348def0c7"].firstMatch
        for _ in 0..<12 {
            if tile.exists && tile.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(tile.exists && tile.isHittable)
        tile.tap()
        XCTAssertTrue(app.buttons["reader.more"].firstMatch.waitForExistence(timeout: 30))
    }

    /// Listen is the direct tool when it was used last; otherwise it is under More.
    private func activateListenTool(_ app: XCUIApplication) {
        if let direct = app.buttons.matching(identifier: "reader.listen").allElementsBoundByIndex.first(where: \.isHittable) {
            direct.tap()
            return
        }
        let more = app.buttons["reader.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let command = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "reader.listen", "Play")).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 5), "More must expose the Listen tool")
        command.tap()
    }

    private func wait(timeout: TimeInterval = 8, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
