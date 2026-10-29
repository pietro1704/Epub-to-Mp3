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

    func testOptInExistingBookNavigation() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_LIVE_PLAYBACK"] == "1",
              let bookID = ProcessInfo.processInfo.environment["APP_DEVICE_READER_BOOK_ID"] else {
            throw XCTSkip("Requires explicit physical-device playback authorization and an existing book ID.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        closeExpandedPlayerIfPresent(app)
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let search = app.buttons["reader.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        attach(app, name: "live-existing-reader")

        search.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("verification-no-match-792680")
        let prompt = app.alerts.firstMatch
        prompt.buttons["Cancel"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        attach(app, name: "live-after-search-cancel")
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5), "Cancel must dismiss the search prompt.")
        XCTAssertTrue(search.waitForExistence(timeout: 5))

        app.buttons["reader.toc.toggle"].firstMatch.tap()
        XCTAssertTrue(app.tables["reader.toc"].cells.firstMatch.waitForExistence(timeout: 5))
        attach(app, name: "live-existing-toc")
        app.navigationBars.buttons["Done"].firstMatch.tap()
        app.buttons["reader.settings.toggle"].firstMatch.tap()
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        attach(app, name: "live-existing-reader-settings")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

    }

    func testOptInExistingBookRealPlayback() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_LIVE_PLAYBACK"] == "1",
              let bookID = ProcessInfo.processInfo.environment["APP_DEVICE_READER_BOOK_ID"] else {
            throw XCTSkip("Requires explicit physical-device playback authorization and an existing book ID.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        closeExpandedPlayerIfPresent(app)
        let tile = app.descendants(matching: .any)["library.bookTile.\(bookID)"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 30))
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let search = app.buttons["reader.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 60))
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        attach(app, name: "live-existing-reader")

        let play = app.buttons["miniPlayer.playPause"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        XCTAssertEqual(play.label.lowercased(), "play", "Opening a book must not autoplay.")
        play.tap()
        let open = app.buttons["miniPlayer.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 90))
        open.tap()
        let elapsed = app.staticTexts["fullPlayer.elapsed"].firstMatch
        XCTAssertTrue(elapsed.waitForExistence(timeout: 90))
        if let expectedVoice = ProcessInfo.processInfo.environment["APP_DEVICE_EXPECTED_VOICE"] {
            let voice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedVoice)).firstMatch
            XCTAssertTrue(voice.waitForExistence(timeout: 90), "Playback must identify the requested Piper voice.")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Eddy")).firstMatch.exists)
        }
        func seconds() -> Int {
            elapsed.label.split(separator: ":").compactMap { Int($0) }.reduce(0) { $0 * 60 + $1 }
        }
        func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 15) -> Bool {
            let condition = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
            return XCTWaiter.wait(for: [condition], timeout: timeout) == .completed
        }
        let initial = seconds()
        XCTAssertTrue(waitFor({ seconds() > initial }, timeout: 60), "Real playback must advance; no canned audio is injected.")
        attach(app, name: "live-real-playback")
        let pause = app.buttons["Pause"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.tap()
        let resume = app.buttons["Play"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        let paused = seconds()
        let interval = expectation(description: "Observe explicit pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { interval.fulfill() }
        wait(for: [interval], timeout: 4)
        XCTAssertLessThanOrEqual(abs(seconds() - paused), 1)
        resume.tap()
        XCTAssertTrue(waitFor({ seconds() > paused }))
        let beforeBackground = seconds()
        XCUIDevice.shared.press(.home)
        let backgroundInterval = expectation(description: "Observe background playback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { backgroundInterval.fulfill() }
        wait(for: [backgroundInterval], timeout: 12)
        app.activate()
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(seconds(), beforeBackground + 5)
        attach(app, name: "live-return-from-background")
        pause.tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
    }

    func testOptInInstallAndAuditionAuthorizedPiperPair() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_INSTALL_PIPER_PAIR"] == "1" else {
            throw XCTSkip("Requires explicit installation and persistent Piper preference authorization.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        closeExpandedPlayerIfPresent(app)
        let settings = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        func reveal(_ element: XCUIElement) {
            for attempt in 0..<32 {
                let viewport = table.frame.intersection(app.frame).insetBy(dx: 0, dy: 12)
                if element.exists {
                    let frame = element.frame
                    if !frame.isEmpty && !frame.isInfinite {
                        if viewport.contains(frame) { return }
                        if frame.midY < viewport.midY { table.swipeDown() }
                        else { table.swipeUp() }
                        continue
                    }
                }
                if attempt < 12 { table.swipeUp() } else { table.swipeDown() }
            }
            XCTFail("The requested model or preference must be reachable.")
        }
        func choose(_ prefix: String, rowID: String) {
            let row = app.cells[rowID].firstMatch
            reveal(row)
            row.tap()
            let choice = app.sheets.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            choice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            XCTAssertTrue((row.value as? String ?? "").hasPrefix(prefix))
        }
        // The user explicitly requested Piper only; persist this before downloads.
        choose("None", rowID: "settings.tts.secondary")
        let online = app.switches["settings.tts.onlineConsent"].firstMatch
        reveal(online)
        if online.value as? String == "1" { online.tap() }
        XCTAssertEqual(online.value as? String, "0")
        let disclosure = app.cells["settings.speechModels.disclosure"].firstMatch
        reveal(disclosure)
        disclosure.tap()
        for (modelID, languageName) in [("pt_BR-faber-medium", "Portuguese (Brazil)"),
                                        ("en_US-ljspeech-high", "English (United States)")] {
            let language = app.cells["settings.speechModels.language"].firstMatch
            reveal(language)
            language.tap()
            let languageChoice = app.sheets.buttons[languageName].firstMatch
            XCTAssertTrue(languageChoice.waitForExistence(timeout: 5))
            languageChoice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 5))
            let model = app.cells["settings.speechModel.\(modelID)"].firstMatch
            reveal(model)
            XCTAssertTrue(model.exists)
            func isInstalled() -> Bool {
                let value = model.value as? String ?? ""
                return value.hasPrefix("Installed ·") || value == "Installed" || value.hasPrefix("Installation completed")
            }
            if !isInstalled() {
                model.tap()
                let install = app.sheets.buttons["Install"].firstMatch
                XCTAssertTrue(install.waitForExistence(timeout: 5))
                install.tap()
                let confirm = app.alerts.buttons["Confirm installation"].firstMatch
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                confirm.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
                let installed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    isInstalled()
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [installed], timeout: 180), .completed,
                               "The explicitly authorized model must finish installation: \(model.value ?? "missing")")
            }
            reveal(model)
            attach(app, name: "installed-\(modelID)")
            model.tap()
            let sample = app.sheets.buttons["Hear voice sample"].firstMatch
            XCTAssertTrue(sample.waitForExistence(timeout: 5))
            sample.tap()
            let sampleText = modelID.hasPrefix("pt_")
                ? "Esta é uma amostra da voz para narrar seus livros. Boa leitura!"
                : "This is a sample of the voice for narrating your books. Enjoy your reading!"
            XCTAssertTrue(app.alerts.staticTexts[sampleText].firstMatch.waitForExistence(timeout: 90),
                          "Observe actual playback before accepting the final idle state.")
            let finished = app.alerts.staticTexts["Sample finished"].firstMatch
            XCTAssertTrue(finished.waitForExistence(timeout: 90), "Strict Piper audition must finish; system fallback is not accepted.")
            attach(app, name: "piper-audition-finished-\(modelID)")
            app.alerts.buttons["Stop sample"].firstMatch.tap()
            XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
            if modelID == "pt_BR-faber-medium" { choose("Faber", rowID: "settings.tts.primary") }
        }
        choose("LJ Speech", rowID: "settings.tts.secondary")
        attach(app, name: "authorized-piper-pair-selected")
        app.terminate()
        app.launch()
        closeExpandedPlayerIfPresent(app)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        for (rowID, name) in [("settings.tts.primary", "Faber"), ("settings.tts.secondary", "LJ Speech")] {
            let row = app.cells[rowID].firstMatch
            reveal(row)
            XCTAssertTrue((row.value as? String ?? "").hasPrefix(name), "Piper preference must survive relaunch.")
        }
        reveal(online)
        XCTAssertEqual(online.value as? String, "0")
        attach(app, name: "authorized-piper-pair-persisted")
    }

    func testOptInDisableAutomaticSystemVoiceFallback() throws {
        guard ProcessInfo.processInfo.environment["APP_DEVICE_DISABLE_SYSTEM_FALLBACK"] == "1" else {
            throw XCTSkip("Requires explicit authorization to persist configured-voices-only recovery.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestResetActiveReader", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        defer { app.terminate() }
        for pass in 0..<2 {
            app.launch()
            closeExpandedPlayerIfPresent(app)
            let settings = app.tabBars.buttons["Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            settings.tap()
            let control = app.switches["settings.tts.automaticSystemFallback"].firstMatch
            let table = app.tables.firstMatch
            for _ in 0..<15 {
                if control.exists && table.frame.insetBy(dx: 0, dy: 12).contains(control.frame) { break }
                table.swipeUp()
            }
            XCTAssertTrue(control.exists)
            if pass == 0 && control.value as? String == "1" { control.tap() }
            XCTAssertEqual(control.value as? String, "0", "Configured-only recovery must survive relaunch.")
            for (identifier, expected) in [("settings.tts.primary", "Faber"),
                                           ("settings.tts.secondary", "LJ Speech"),
                                           ("settings.speechModels.disclosure", "Collapsed")] {
                let row = app.cells[identifier].firstMatch
                for _ in 0..<20 {
                    let viewport = table.frame.insetBy(dx: 0, dy: 12)
                    if row.exists && viewport.contains(row.frame) { break }
                    if row.exists && row.frame.midY > viewport.midY { table.swipeUp() }
                    else { table.swipeDown() }
                }
                XCTAssertTrue((row.value as? String ?? "").hasPrefix(expected))
            }
            attach(app, name: "configured-only-voices-persisted-\(pass)")
            app.terminate()
        }
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
