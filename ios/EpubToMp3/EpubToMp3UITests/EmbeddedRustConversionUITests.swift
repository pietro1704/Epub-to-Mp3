import XCTest

@MainActor
final class EmbeddedRustConversionUITests: XCTestCase {
    func testSeedBookOpensWithEmbeddedRustReaderAndNoClippedLines() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launch()

        let bookTile = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        XCTAssertTrue(bookTile.waitForExistence(timeout: 30), "The seeded book must be visible in the library.")
        let readerHarness = ReaderModesHarness(app: app)
        let configuration = ReaderModesHarness.LaunchConfiguration(
            source: .seededLOTR,
            layout: "paginated",
            smallFont: false,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true,
            additionalArguments: ["-uiTestRustConversionProbe"]
        )
        _ = readerHarness.launch(configuration)
        try readerHarness.openBook(titleContaining: "Lord of the Rings")

        let reader = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The seeded EPUB must open without backend parsing.")
        XCTAssertTrue(app.buttons["reader.more"].waitForExistence(timeout: 10))

        let unavailableError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Embedded converter artifact is unavailable")
        ).firstMatch
        XCTAssertFalse(unavailableError.exists, "Opening the EPUB must not report a missing embedded converter.")

        let backendError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "backend URL")
        ).firstMatch
        XCTAssertFalse(backendError.waitForExistence(timeout: 1), "Conversion must not fall back to a backend URL.")

        readerHarness.assertNoClippedLines(scenario: "seeded EPUB initial page")
    }
}

/// Exercise the real settings and manual selection controls without synthesis or downloads.
@MainActor
final class TtsPreferencesUITests: XCTestCase {
    func testSettingsAndManualOverrideAreReachableAndKeepDefaultsSeparate() throws {
        // TTS-MENU-UI-AUTOMATION: the Models narration rows are UIMenu buttons. On the 16e (iOS 26) XCUITest exposes an
        // overlapping accessibility element for the secondary row, so a coordinate tap on the primary row can hit the
        // wrong menu. The behaviour is covered by ModelsScreenAlertTests (menu structure, one menu per row after reloads,
        // button geometry) and by device screenshots; re-enable once the menu rows can be driven deterministically.
        throw XCTSkip("TTS-MENU-UI-AUTOMATION: UIMenu rows are not drivable by XCUITest yet")
        continueAfterFailure = false
        let app = XCUIApplication()
        // Isolated settings: this test changes narration and consent and must not touch the real app's preferences.
        app.launchArguments = ["-uiTestFixture", "-uiTestIsolatedSettings",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 10))
        openModels(app)
        let primary = app.buttons["settings.tts.primary"]
        reveal(primary, in: app)
        let originalPrimary = try XCTUnwrap(primary.value as? String)
        let secondary = app.buttons["settings.tts.secondary"]
        reveal(secondary, in: app)
        let originalSecondary = try XCTUnwrap(secondary.value as? String)
        let online = app.switches["settings.tts.onlineConsent"]
        reveal(online, in: app)
        let originalOnline = online.value as? String == "1"
        defer {
            openModels(app)
            chooseNarration(originalPrimary, row: primary, app: app)
            chooseNarration(originalSecondary, row: secondary, app: app)
            setSwitch(online, on: originalOnline, app: app)
        }

        chooseNarration("Piper, Faber medium", row: primary, app: app)
        chooseNarration("None", row: secondary, app: app)
        setSwitch(online, on: false, app: app)
        reveal(primary, in: app)
        XCTAssertTrue((primary.value as? String ?? "").hasPrefix("Piper, ") && (primary.value as? String ?? "").localizedCaseInsensitiveContains("faber"), "primary: \(String(describing: primary.value))")
        reveal(secondary, in: app)
        XCTAssertEqual(secondary.value as? String, "None")
        reveal(online, in: app)
        XCTAssertEqual(online.value as? String, "0")

        chooseNarration("System, Luciana when available", row: secondary, app: app)
        reveal(secondary, in: app)
        XCTAssertEqual(secondary.value as? String, "System, Luciana when available")
        reveal(primary, in: app)
        XCTAssertTrue((primary.value as? String ?? "").hasPrefix("Piper, ") && (primary.value as? String ?? "").localizedCaseInsensitiveContains("faber"), "primary: \(String(describing: primary.value))")

        chooseNarration("Edge", row: secondary, app: app)
        setSwitch(online, on: true, app: app)
        app.tabBars.buttons["Convert"].tap()
        let manual = app.cells["convert.tts.primary"]
        reveal(manual, in: app)
        XCTAssertEqual(manual.value as? String, "Use preferences")
        let reserve = app.switches["convert.tts.useSecondary"]
        reveal(reserve, in: app)
        XCTAssertEqual(reserve.value as? String, "1", "Inherited selection must show the configured secondary.")
        XCTAssertFalse(reserve.isEnabled, "Inherited policy is configured in Settings.")
        let inheritedControl = XCTAttachment(screenshot: app.screenshot())
        inheritedControl.name = "tts-inherited-secondary-visible"
        inheritedControl.lifetime = .keepAlways
        add(inheritedControl)

        choose("Edge", row: manual, app: app)
        XCTAssertEqual(manual.value as? String, "Edge")
        reveal(reserve, in: app)
        XCTAssertFalse(reserve.isEnabled, "The saved secondary duplicates the explicit primary.")
        XCTAssertEqual(reserve.value as? String, "0", "An explicit manual voice starts without a secondary.")
        openModels(app)
        reveal(primary, in: app)
        XCTAssertTrue((primary.value as? String ?? "").localizedCaseInsensitiveContains("faber"), "Manual overrides must not change the default.")
        reveal(secondary, in: app)
        XCTAssertEqual(secondary.value as? String, "Edge")
        app.tabBars.buttons["Convert"].tap()
        reveal(manual, in: app)
        XCTAssertEqual(manual.value as? String, "Edge", "Returning to the conversion must preserve its explicit override.")
        choose("Faber medium", row: manual, app: app)
        setSwitch(reserve, on: true, app: app)
        XCTAssertEqual(reserve.value as? String, "1")
        choose("Edge", row: manual, app: app)
        reveal(reserve, in: app)
        XCTAssertFalse(reserve.isEnabled)
        XCTAssertEqual(reserve.value as? String, "0", "Changing the explicit engine must reset its secondary opt-in.")
        choose("Use preferences", row: manual, app: app)
        reveal(reserve, in: app)
        XCTAssertFalse(reserve.isEnabled)
        XCTAssertEqual(reserve.value as? String, "1")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "tts-manual-inherited-policy"
        attachment.lifetime = .keepAlways
        add(attachment)

        let voice = app.textFields["Voice (optional)"]
        reveal(voice, in: app)
        voice.tap()
        voice.typeText(" \n") // Trimmed to nil: keep the Faber selection valid.
        XCTAssertEqual(manual.value as? String, "Faber medium")
        reveal(reserve, in: app)
        XCTAssertTrue(reserve.isEnabled, "Editing an inherited voice must immediately enable the manual secondary control.")
        XCTAssertEqual(reserve.value as? String, "0")
    }

    /// The narration rows live on the Models screen (the single Models row of Settings pushes it).
    private func openModels(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Settings"]
        for _ in 0..<4 {
            tab.tap()
            let selected = NSPredicate(format: "isSelected == true")
            if XCTWaiter().wait(for: [expectation(for: selected, evaluatedWith: tab)], timeout: 2) == .completed { break }
        }
        XCTAssertTrue(tab.isSelected, "The Settings tab did not open")
        if app.buttons["settings.tts.primary"].waitForExistence(timeout: 1) { return }
        let row = app.cells["settings.speechModels.disclosure"]
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.buttons["settings.tts.primary"].waitForExistence(timeout: 5), "The Models screen did not open")
    }

    /// Settings narration rows open an engine-first menu (System / Piper / Edge, the voice inside the engine).
    /// `value` is the row's accessibility value: "<engine>[, <voice>]" or "None". Each tap applies at once.
    private func chooseNarration(_ value: String, row: XCUIElement, app: XCUIApplication) {
        reveal(row, in: app)
        // A real touch at the centre of the menu button: `isHittable` cannot resolve an activation point for it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let parts = value.components(separatedBy: ", ")
        let engine = parts[0]
        let voice = parts.count > 1 ? parts.dropFirst().joined(separator: ", ") : nil
        let entry = app.buttons[engine]
        XCTAssertTrue(entry.waitForExistence(timeout: 3), "Missing engine in the menu: \(engine)")
        // The menu springs open; tapping during the animation lands on the neighbouring (disabled) item.
        Thread.sleep(forTimeInterval: 1)
        let open = XCTAttachment(screenshot: app.screenshot())
        open.name = "narration-menu-open-\(engine)"
        open.lifetime = .keepAlways
        add(open)
        let labels = XCTAttachment(string: app.buttons.allElementsBoundByIndex.map { "\($0.elementType.rawValue) \($0.identifier) | \($0.label) | \($0.frame)" }.joined(separator: "\n"))
        labels.name = "narration-menu-buttons-\(engine)"
        labels.lifetime = .keepAlways
        add(labels)
        entry.tap()
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "narration-menu-after-\(engine)"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "narration-menu-tree-after-\(engine)"
        tree.lifetime = .keepAlways
        add(tree)
        // System offers a detail label rather than a voice list; only Piper opens a submenu.
        if engine == "Piper", let voice {
            // The device lists the Faber model as "Faber medium" or by its id (`pt_BR-faber-medium`).
            let exact = app.buttons[voice]
            let leaf = voice.lowercased().contains("faber")
                ? app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "faber")).firstMatch
                : exact
            XCTAssertTrue(leaf.waitForExistence(timeout: 3), "Missing Piper model in the menu: \(voice)")
            Thread.sleep(forTimeInterval: 1)
            leaf.tap()
        }
        XCTAssertTrue(entry.waitForNonExistence(timeout: 3), "The menu must close after the choice")
    }

    private func choose(_ title: String, row: XCUIElement, app: XCUIApplication) {
        reveal(row, in: app)
        row.tap()
        let action = app.sheets.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 3), "Missing native selection: \(title)")
        action.tap()
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 3))
    }

    private func setSwitch(_ control: XCUIElement, on: Bool, app: XCUIApplication) {
        reveal(control, in: app)
        XCTAssertTrue(control.isEnabled)
        if (control.value as? String == "1") != on { control.tap() }
        XCTAssertEqual(control.value as? String, on ? "1" : "0")
    }

    private func isVisible(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        // The Models narration rows are menu buttons whose hittability XCUITest cannot resolve; judge by frame.
        if element.exists, element.identifier.hasPrefix("settings.tts."), element.elementType == .button {
            return !element.frame.isEmpty && app.frame.contains(element.frame)
        }
        return element.exists && (element.isHittable || (!element.isEnabled && app.frame.contains(element.frame)))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let table = app.tables.firstMatch
        for _ in 0..<30 {
            if isVisible(element, app: app) { return }
            // Full swipes can jump over a disabled switch on the SE. Its
            // accessibility frame remains available outside the viewport;
            // follow that position with short drags instead of overshooting.
            let above = element.exists && element.frame.midY < table.frame.midY
            let start = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.4 : 0.6))
            let end = table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.6 : 0.4))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(isVisible(element, app: app), "The control must be reachable on the iPhone SE: \(element); exists=\(element.exists), enabled=\(element.isEnabled), frame=\(element.frame), appFrame=\(app.frame)")
    }
}
