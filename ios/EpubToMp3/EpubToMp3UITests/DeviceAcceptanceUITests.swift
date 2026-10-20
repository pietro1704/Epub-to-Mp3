import XCTest

/// Offline acceptance through the shipped navigation, without clearing reader progress.
@MainActor
final class DeviceAcceptanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testEnglishLightLibraryJobsConversionAndReaderAccessibility() throws {
        try auditNavigation(portuguese: false)
    }

    func testPortugueseDarkLargeTextLibraryJobsConversionAndReaderAccessibility() throws {
        try auditNavigation(portuguese: true)
    }

    func testExistingDeviceBookChromePreservesRawPositionWithoutClearingProgress() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-uiTestReaderLayout", "paginated",
            "-uiTestChromeToggle", "-uiTestPaginationProbe", "-uiTestNoPageTurnOverlay",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        closeExpandedPlayerIfPresent(app)
        let harness = ReaderModesHarness(app: app)
        let bookID = ProcessInfo.processInfo.environment["APP_DEVICE_READER_BOOK_ID"]
            ?? "1748a144d1c2e8b06c2663efa2a13398"
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30), "The literal existing device book is required; no import or synthetic substitution.")
        guard tile.exists else { return }
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let close = app.buttons["reader.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        defer { if close.exists && close.isHittable { close.tap() } }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let metrics = harness.paginationMetrics,
               (metrics.values["first"] ?? -1) >= 0, (metrics.values["total"] ?? 0) > 0 { break }
            usleep(100_000)
        }
        harness.toggleChromeAndSettle(visible: true)
        audit(app, surface: "actual-device-book-visible-chrome")
        let initial = try XCTUnwrap(harness.paginationMetrics)
        XCTAssertNotNil(initial.values["offset"])
        XCTAssertNotNil(initial.values["first"])
        harness.assertNoClippedLines(scenario: "Existing book before chrome round trip")
        harness.toggleChromeAndSettle(visible: false)
        harness.assertNoClippedLines(scenario: "Existing book hidden chrome")
        attach(app, name: "actual-device-book-hidden-chrome")
        harness.toggleChromeAndSettle(visible: true)
        let restored = try XCTUnwrap(harness.paginationMetrics)
        XCTAssertEqual(restored.values["offset"], initial.values["offset"], "Chrome must restore the exact raw offset.")
        XCTAssertEqual(restored.values["first"], initial.values["first"], "Chrome must preserve the visible passage.")
        harness.assertNoClippedLines(scenario: "Existing book restored chrome")
        let evidence = XCTAttachment(string: "bookID=\(bookID)\ninitial=\(initial.values)\nrestored=\(restored.values)")
        evidence.name = "existing-book-position-evidence"
        evidence.lifetime = .keepAlways
        add(evidence)
        attach(app, name: "actual-device-book-restored-chrome")
    }

    private func auditNavigation(portuguese: Bool) throws {
        let app = XCUIApplication()
        let language = portuguese ? "pt-BR" : "en"
        let theme = portuguese ? "dark" : "light"
        app.launchArguments = ["-uiTestFixture", "-AppleLanguages", "(\(language))",
            "-AppleLocale", portuguese ? "pt_BR" : "en_US", "-AppleInterfaceStyle", portuguese ? "Dark" : "Light",
            "-readerTheme", theme]
        if portuguese {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        let library = tabs.buttons[portuguese ? "Biblioteca" : "Library"]
        let settings = tabs.buttons[portuguese ? "Ajustes" : "Settings"]
        let convert = tabs.buttons[portuguese ? "Converter" : "Convert"]
        guard assertControl(library, app: app) else { return }
        library.tap()
        XCTAssertTrue(app.searchFields["library.searchField"].waitForExistence(timeout: 5))
        audit(app, surface: "\(language)-library")

        guard assertControl(settings, app: app) else { return }
        settings.tap()
        audit(app, surface: "\(language)-settings-top")
        let recent = app.cells.containing(.staticText, identifier: portuguese ? "Trabalhos recentes" : "Recent jobs").firstMatch
        let settingsTable = app.tables.firstMatch
        scrollTo(recent, in: settingsTable)
        guard assertControl(recent, app: app) else { return }
        audit(app, surface: "\(language)-settings-advanced")
        recent.tap()
        let refresh = app.buttons[portuguese ? "Atualizar trabalhos" : "Refresh jobs"].firstMatch
        guard assertControl(refresh, app: app) else { return }
        refresh.tap()
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForNonExistence(timeout: 15), "Local history refresh must settle.")
        audit(app, surface: "\(language)-jobs-local-history")

        guard assertControl(convert, app: app) else { return }
        convert.tap()
        audit(app, surface: "\(language)-convert")
        let picker = app.cells.containing(.staticText, identifier: portuguese ? "Escolher EPUB ou PDF" : "Pick EPUB or PDF").firstMatch
        scrollTo(picker, in: app.tables.firstMatch)
        guard assertControl(picker, app: app) else { return }
        picker.tap()
        let cancel = app.buttons[portuguese ? "Cancelar" : "Cancel"].firstMatch
        guard assertControl(cancel, app: app) else { return }
        attach(app, name: "\(language)-native-picker")
        cancel.tap()
        library.tap()
        let tile = app.descendants(matching: .any)["library.bookTile.ui-test-book"].firstMatch
        guard assertControl(tile, app: app) else { return }
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let content = app.textViews["reader.content"].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 20), "Synthetic reader must become usable without conversion.")
        audit(app, surface: "\(language)-reader")
        let close = app.buttons["reader.close"].firstMatch
        if assertControl(close, app: app) { close.tap() }
        attach(app, name: "\(language)-library-after-reader")
    }

    private func audit(_ app: XCUIApplication, surface: String) {
        attach(app, name: surface)
        if #available(iOS 17.0, *) {
            var descriptions: [String] = []
            var completed = false
            do {
                try app.performAccessibilityAudit(for: .all) { issue in
                    descriptions.append("\(issue.auditType.rawValue): \(issue.detailedDescription)")
                    return false // Every native issue remains an XCTest failure.
                }
                completed = true
            } catch {
                XCTFail("Accessibility audit could not complete on \(surface): \(error)")
            }
            let status = completed ? "Native rendered accessibility audit completed." : "Native rendered accessibility audit did not complete; no clean-audit conclusion is available."
            let evidence = XCTAttachment(string: status + "\n" + (descriptions.isEmpty ? "No issue descriptions collected." : descriptions.joined(separator: "\n\n")))
            evidence.name = "\(surface)-accessibility-issues"
            evidence.lifetime = .keepAlways
            add(evidence)
        } else {
            let evidence = XCTAttachment(string: "Native rendered accessibility audit is unsupported before iOS 17. This surface was exercised through navigation, screenshots and explicit control assertions only; rendered contrast, dynamic-type and hit-region audits were not executed.")
            evidence.name = "\(surface)-rendered-accessibility-audit-unsupported"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
    }

    @discardableResult
    private func assertControl(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        let exists = element.waitForExistence(timeout: 8)
        XCTAssertTrue(exists, "Required control must exist: \(element)")
        guard exists else { return false }
        XCTAssertTrue(element.isHittable, "Required control must remain reachable: \(element)")
        XCTAssertFalse(element.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Required control needs a spoken name.")
        XCTAssertTrue(app.windows.firstMatch.frame.intersects(element.frame), "Required control must intersect the window.")
        return element.isHittable
    }

    private func scrollTo(_ element: XCUIElement, in table: XCUIElement) {
        for _ in 0..<40 {
            if element.exists && element.isHittable { return }
            table.swipeUp(velocity: .fast)
        }
        XCTFail("Required destination is unreachable after bounded scrolling: \(element)")
    }

    private func closeExpandedPlayerIfPresent(_ app: XCUIApplication) {
        let close = app.buttons["fullPlayer.close"].firstMatch
        if close.waitForExistence(timeout: 2), close.isHittable { close.tap() }
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
