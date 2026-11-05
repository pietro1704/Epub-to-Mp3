import XCTest

/// Exercises the installed book and real typography controls without replacing
/// the library or triggering conversion/model downloads.
@MainActor
final class PhysicalReaderTypographyJourneyTests: XCTestCase {
    func testReaderFontFamiliesAndPagination() throws {
        let app = try openInstalledReader()
        defer { app.terminate() }
        assertReader(app, name: "baseline")
        let indicator = app.staticTexts["reader.pageIndicator"].firstMatch
        let initialPage = indicator.value as? String
        app.scrollViews["reader.viewport"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(wait { (indicator.value as? String) != initialPage })
        assertReader(app, name: "page-forward")
        app.scrollViews["reader.viewport"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(wait { (indicator.value as? String) == initialPage }, "Page round trip must restore the initial page")

        // Each installed family is selected through the same catalogue the user sees.
        openSettings(app)
        let family = app.cells["reader.settings.fontFamily"].firstMatch
        reveal(family, in: app)
        family.tap()
        let families = app.tables["reader.fontCatalog"].cells.allElementsBoundByIndex.map(\.identifier)
        XCTAssertGreaterThan(families.count, 3)
        tap(app.navigationBars.buttons.element(boundBy: 0), in: app)
        tap(app.buttons["Done"].firstMatch, in: app)
        for identifier in families {
            openSettings(app)
            reveal(family, in: app)
            family.tap()
            let choice = app.cells[identifier].firstMatch
            reveal(choice, in: app)
            choice.tap()
            tap(app.navigationBars.buttons.element(boundBy: 0), in: app)
            tap(app.buttons["Done"].firstMatch, in: app)
            assertReader(app, name: identifier)
        }

    }

    func testFontSizeChangesRenderedPagination() throws {
        let app = try openInstalledReader()
        defer { app.terminate() }
        var pageCounts: [Int] = []
        for fraction: CGFloat in [0, 1] {
            openSettings(app)
            let slider = app.descendants(matching: .any)["reader.settings.fontSize"].firstMatch
            reveal(slider, in: app)
            let inset = 9 / slider.frame.width
            slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset:
                    CGVector(dx: inset + fraction * (1 - 2 * inset), dy: 0.5)))
            tap(app.buttons["Done"].firstMatch, in: app)
            assertReader(app, name: "font-size-effective-\(fraction)")
            let label = app.staticTexts["reader.paginationProbe"].firstMatch.label
            let total = label.split(separator: ";").first { $0.hasPrefix("total=") }
                .flatMap { Int($0.dropFirst(6)) }
            pageCounts.append(try XCTUnwrap(total))
        }
        XCTAssertGreaterThan(pageCounts[1], pageCounts[0], "The largest font must visibly repaginate the same long chapter")
    }

    func testThemesAlignmentPageStylesAndOrientation() throws {
        let app = try openInstalledReader()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        for theme in ["Default", "Light", "Sepia", "Parchment", "Paper", "Dark", "Black"] {
            openSettings(app)
            let row = app.cells.matching(NSPredicate(format: "label == %@", theme)).firstMatch
            reveal(row, in: app)
            row.tap()
            tap(app.buttons["Done"].firstMatch, in: app)
            assertReader(app, name: "theme-\(theme)")
        }
        for alignment in ["Left", "Justified"] {
            openSettings(app)
            let row = app.cells["reader.settings.layout.row.3"].firstMatch
            reveal(row, in: app)
            row.tap()
            app.buttons[alignment].firstMatch.tap()
            tap(app.buttons["Done"].firstMatch, in: app)
            assertReader(app, name: "alignment-\(alignment)")
        }
        for style in ["Flip", "Slide", "Normal"] {
            openSettings(app)
            let row = app.cells["reader.settings.layout.row.1"].firstMatch
            reveal(row, in: app)
            row.tap()
            app.buttons[style].firstMatch.tap()
            tap(app.buttons["Done"].firstMatch, in: app)
            let indicator = app.staticTexts["reader.pageIndicator"].firstMatch
            let initial = indicator.value as? String
            let viewport = app.scrollViews["reader.viewport"].firstMatch
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            XCTAssertTrue(wait { (indicator.value as? String) != initial })
            assertReader(app, name: "page-style-\(style)-forward")
            viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
            XCTAssertTrue(wait { (indicator.value as? String) == initial })
            assertReader(app, name: "page-style-\(style)-backward")
        }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(wait {
                let frame = app.windows.firstMatch.frame
                return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
            })
            assertReader(app, name: "reader-orientation-\(orientation.rawValue)")
        }
    }

    func testReaderMarginsSpacingAndTrackingControls() throws {
        let app = try openInstalledReader()
        defer { app.terminate() }
        let mode = app.cells["reader.settings.mode"].firstMatch
        // Cover endpoints and intermediate settings without a costly Cartesian product.
        for identifier in ["reader.settings.margin", "reader.settings.lineSpacing"] {
            for fraction: CGFloat in [0, 0.5, 1] {
                openSettings(app)
                let slider = app.descendants(matching: .any)[identifier].firstMatch
                reveal(slider, in: app)
                let inset = 9 / slider.frame.width
                slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: slider.coordinate(withNormalizedOffset:
                        CGVector(dx: inset + fraction * (1 - 2 * inset), dy: 0.5)))
                tap(app.buttons["Done"].firstMatch, in: app)
                assertReader(app, name: "\(identifier)-\(fraction)")
            }
        }

        openSettings(app)
        let tracking = app.switches["reader.settings.audioTracking"].firstMatch
        reveal(tracking, in: app)
        let initial = tracking.value as? String
        tracking.tap()
        XCTAssertNotEqual(tracking.value as? String, initial)
        tap(app.buttons["Done"].firstMatch, in: app)
        openSettings(app)
        reveal(tracking, in: app)
        XCTAssertNotEqual(tracking.value as? String, initial, "Tracking choice must survive reopening Aa")
        tracking.tap()
        XCTAssertEqual(tracking.value as? String, initial)
        reveal(mode, in: app, scrollDown: true)
        mode.tap(); app.buttons["Scrolling"].firstMatch.tap()
        tap(app.buttons["Done"].firstMatch, in: app)
        XCTAssertFalse(app.staticTexts["reader.pageIndicator"].firstMatch.exists)
        let content = app.textViews["reader.content"].firstMatch
        XCTAssertTrue(content.isHittable)
        app.scrollViews["reader.viewport"].firstMatch.swipeUp()
        capture(app, "scrolling-after-typography")
        app.buttons["reader.close"].firstMatch.tap()
        app.tabBars.buttons["Settings"].firstMatch.tap()
        let globalTracking = app.switches["settings.reader.audioTracking"].firstMatch
        reveal(globalTracking, in: app)
        let globalInitial = globalTracking.value as? String
        globalTracking.tap()
        XCTAssertNotEqual(globalTracking.value as? String, globalInitial)
        globalTracking.tap()
        XCTAssertEqual(globalTracking.value as? String, globalInitial)
        capture(app, "global-tracking-toggle-round-trip")
    }

    private func openInstalledReader() throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_AUDIOBOOK_ACCEPTANCE"] == "1",
              ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] == "com.pietrocode.epubtomp3" else {
            throw XCTSkip("Requires explicit physical app acceptance")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestPaginationProbe", "-developmentSeedBook"]
        app.launch()
        for identifier in ["fullPlayer.close", "reader.close", "mainReader.browseLibrary"] {
            dismissBanners(app)
            let button = app.buttons[identifier].firstMatch
            if button.exists && button.isHittable { button.tap() }
        }
        let library = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), app.debugDescription)
        library.tap()
        let book = app.cells["library.bookTile.3e1c676b270dfa3fe555eba4d0cb9934"].firstMatch
        let grid = app.collectionViews.firstMatch
        for _ in 0..<4 where !book.isHittable { grid.swipeDown() }
        for _ in 0..<12 where !book.isHittable { grid.swipeUp() }
        XCTAssertTrue(book.isHittable, app.debugDescription)
        book.tap()
        XCTAssertTrue(app.buttons["reader.settings.toggle"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))

        openSettings(app)
        let mode = app.cells["reader.settings.mode"].firstMatch
        reveal(mode, in: app)
        if (mode.value as? String) != "Paginated" {
            mode.tap(); app.buttons["Paginated"].firstMatch.tap()
        }
        tap(app.buttons["Done"].firstMatch, in: app)
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        dismissBanners(app)
        let button = app.buttons["reader.settings.toggle"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        if !app.buttons["Done"].firstMatch.waitForExistence(timeout: 3), app.state != .runningForeground {
            app.activate()
            dismissBanners(app)
            button.tap()
        }
        XCTAssertTrue(app.buttons["Done"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    private func dismissBanners(_ app: XCUIApplication) {
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
        if banner.exists { banner.swipeUp() }
        if app.state != .runningForeground { app.activate() }
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        dismissBanners(app)
        element.tap()
        if app.state != .runningForeground {
            app.activate()
            dismissBanners(app)
            element.tap()
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollDown: Bool = false) {
        let table = app.tables.firstMatch
        for _ in 0..<14 where !element.isHittable {
            if scrollDown { table.swipeDown() }
            else { table.swipeUp() }
        }
        XCTAssertTrue(element.isHittable, "Unreachable control: \(element)")
    }

    private func assertReader(_ app: XCUIApplication, name: String) {
        let probe = app.staticTexts["reader.paginationProbe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            probe.label.contains("clippedLineCount=0")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed, probe.label)
        XCTAssertTrue(app.textViews["reader.content"].firstMatch.isHittable)
        capture(app, name)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let metrics = XCTAttachment(string: app.staticTexts.matching(identifier: "reader.paginationProbe")
            .allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
        metrics.name = name + "-metrics"
        metrics.lifetime = .keepAlways
        add(metrics)
    }

    private func wait(_ condition: @escaping () -> Bool) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)],
                      timeout: 5) == .completed
    }
}
