import XCTest

/// Drives only the explicitly staged PDF in the installed app; never resets its library.
@MainActor
final class PhysicalPDFJourneyTests: XCTestCase {
    private var application: XCUIApplication?

    override func tearDownWithError() throws {
        if let application, application.state == .runningForeground {
            capture(application, name: "pdf-journey-final-state")
        }
        // The host owns final cleanup so a failed journey remains inspectable.
        application = nil
    }

    func testStagedPDFOpensConvertsAndPlaysWithPauseAndResume() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_PDF_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit physical PDF acceptance only")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone only")
        #else
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] == "com.pietrocode.epubtomp3",
              environment["EPUB2MP3_PHYSICAL_PDF_BOOK_ID"] == "374b286bbf7c17b65650e037eaca934f" else {
            throw XCTSkip("Requires the audited application and two-page PDF fixture identity")
        }
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        application = app
        // Argument-domain locale overrides do not change the user's saved settings.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestReduceMotion"]
        app.launch()
        XCTAssertEqual(app.state, .runningForeground)
        dismissPlayer(app)
        openLibrary(app)
        let tile = app.cells["library.bookTile.374b286bbf7c17b65650e037eaca934f"]
        XCTAssertTrue(tile.waitForExistence(timeout: 15), "The staged PDF must already be imported")
        XCTAssertTrue(tile.label.contains("Validação PDF para áudio") || tile.staticTexts["Validação PDF para áudio"].exists)
        capture(app, name: "pdf-01-imported-fixture")

        tile.tap()
        XCTAssertTrue(app.buttons["reader.toc.toggle"].waitForExistence(timeout: 15))
        let firstPage = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Parte 1")
        ).firstMatch
        XCTAssertTrue(firstPage.waitForExistence(timeout: 15), "The native PDF surface must expose its first-page text")
        capture(app, name: "pdf-02-native-reader")

        openLibrary(app)
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.press(forDuration: 1.2)
        let download = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Download entire book", "Baixar livro inteiro"]
        )).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        download.tap()
        XCTAssertTrue(app.cells["convert.tts.primary"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["bookDetail.listen"].exists)
        let completed = app.staticTexts["Conversion completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 180), app.debugDescription)
        capture(app, name: "pdf-03-conversion-complete")
        openLibrary(app)
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        XCTAssertTrue(app.buttons["reader.toc.toggle"].waitForExistence(timeout: 10))
        app.buttons["miniPlayer.playPause"].tap()
        app.buttons["miniPlayer.open"].tap()
        XCTAssertTrue(app.buttons["fullPlayer.close"].waitForExistence(timeout: 30))
        let transport = app.buttons.matching(NSPredicate(
            format: "label IN %@ AND identifier != %@",
            ["Play", "Pause", "Reproduzir", "Pausar"], "miniPlayer.playPause"
        )).firstMatch
        waitUntil(seconds: 30) { ["Pause", "Pausar"].contains(transport.label) }
        XCTAssertTrue(["Pause", "Pausar"].contains(transport.label))
        let elapsed = app.staticTexts["fullPlayer.elapsed"]
        XCTAssertTrue(elapsed.exists)
        let started = elapsed.label
        waitUntil(seconds: 8) { elapsed.label != started }
        XCTAssertNotEqual(elapsed.label, started)
        capture(app, name: "pdf-04-audible-playback-progress")

        transport.tap()
        waitUntil(seconds: 5) { ["Play", "Reproduzir"].contains(transport.label) }
        XCTAssertTrue(["Play", "Reproduzir"].contains(transport.label))
        Thread.sleep(forTimeInterval: 0.5)
        let paused = elapsed.label
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(elapsed.label, paused)
        capture(app, name: "pdf-05-paused")

        transport.tap()
        waitUntil(seconds: 10) { ["Pause", "Pausar"].contains(transport.label) }
        XCTAssertTrue(["Pause", "Pausar"].contains(transport.label))
        waitUntil(seconds: 8) { elapsed.label != paused }
        XCTAssertNotEqual(elapsed.label, paused)
        capture(app, name: "pdf-06-resumed")
        transport.tap()
        waitUntil(seconds: 5) { ["Play", "Reproduzir"].contains(transport.label) }
        XCTAssertTrue(["Play", "Reproduzir"].contains(transport.label))
        app.buttons["fullPlayer.close"].tap()
        #endif
    }

    func testInstalledPDFWithExplicitPrimary() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_PDF_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit physical PDF acceptance only")
        }
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        application = app
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestReduceMotion"]
        app.launch()
        dismissPlayer(app)
        openLibrary(app)
        app.tabBars.buttons["Convert"].tap()
        app.cells.matching(NSPredicate(format: "label == %@", "Pick EPUB or PDF")).firstMatch.tap()
        let document = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "EpubToMp3-PDF-validation-639ccf4")
        ).firstMatch
        capture(app, name: "pdf-document-picker")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "pdf-document-picker-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(document.waitForExistence(timeout: 10), app.debugDescription)
        document.tap()
        let primary = app.cells["convert.tts.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        primary.tap()
        app.sheets.buttons["Piper"].tap()
        let language = app.textFields["Language code (e.g. en, pt) — optional"]
        language.tap()
        language.typeText("pt-BR")
        app.swipeUp()

        let submit = app.cells["convert.submit"]
        for _ in 0..<8 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.isHittable)
        submit.tap()
        let completed = app.staticTexts["Conversion completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 90), app.debugDescription)
        capture(app, name: "pdf-explicit-primary-result")
    }

    func testLibraryDownloadKeepsDirectReaderAndUsesExistingConversion() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_PDF_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Explicit physical PDF acceptance only")
        }
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        application = app
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-uiTestReduceMotion"]
        app.launch()
        dismissPlayer(app)
        openLibrary(app)
        let tile = app.cells["library.bookTile.374b286bbf7c17b65650e037eaca934f"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        XCTAssertTrue(app.buttons["reader.toc.toggle"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["bookDetail.listen"].exists)
        openLibrary(app)
        tile.press(forDuration: 1.2)
        app.buttons["Download entire book"].tap()
        XCTAssertTrue(app.cells["convert.tts.primary"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["bookDetail.listen"].exists)
        capture(app, name: "library-download-existing-conversion")
    }

    private func openLibrary(_ app: XCUIApplication) {
        if app.cells["convert.tts.primary"].exists {
            let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Library", "Biblioteca"])).firstMatch
            if back.exists { back.tap() }
        }
        let readerBack = app.buttons["reader.close"]
        if readerBack.waitForExistence(timeout: 2) { readerBack.tap() }
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Library", "Biblioteca"])).firstMatch
        if !tab.waitForExistence(timeout: 3) {
            let browse = app.buttons["mainReader.browseLibrary"]
            XCTAssertTrue(browse.waitForExistence(timeout: 10), app.debugDescription)
            browse.tap()
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
    }

    private func dismissPlayer(_ app: XCUIApplication) {
        let close = app.buttons["fullPlayer.close"]
        if close.waitForExistence(timeout: 2) { close.tap() }
    }

    private func waitUntil(seconds: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
