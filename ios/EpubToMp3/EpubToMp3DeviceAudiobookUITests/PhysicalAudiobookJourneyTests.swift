import XCTest

/// External-app automation: this target never installs or resets the user's app.
@MainActor
final class PhysicalAudiobookJourneyTests: XCTestCase {
    private var app: XCUIApplication?

    override func tearDownWithError() throws {
        if let app, app.state != .notRunning { app.terminate() }
        app = nil
    }

    func testPhysicalAudiobookJourney() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_AUDIOBOOK_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires an explicitly provisioned isolated app on the physical iPhone")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This journey requires the explicitly authorized physical device")
        #else
        continueAfterFailure = false
        let requested = ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] ?? ""
        let bundle = requested.hasPrefix("com.") ? requested : "com.pietrocode.epubtomp3.iphoneacceptance"
        guard ["com.pietrocode.epubtomp3.iphoneacceptance", "com.pietrocode.epubtomp3.uitests"].contains(bundle) else {
            throw XCTSkip("Only the explicitly isolated acceptance identities are allowed")
        }
        let application = XCUIApplication(bundleIdentifier: bundle)
        app = application
        application.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        application.launch()
        dismissExpandedPlayer(in: application)
        capture(application, name: "01-real-iphone-launch")
        let settings = application.tabBars.buttons["Settings"]
        if !settings.waitForExistence(timeout: 10) {
            let library = application.buttons["mainReader.browseLibrary"].firstMatch
            XCTAssertTrue(library.waitForExistence(timeout: 10), application.debugDescription)
            library.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10), application.debugDescription)
        settings.tap()
        let language = application.cells["settings.speechModels.language"]
        reveal(language, in: application, upward: true)
        XCTAssertTrue(language.waitForExistence(timeout: 10), application.debugDescription)
        capture(application, name: "02-real-iphone-voice-catalogue")
        let hierarchy = XCTAttachment(string: application.debugDescription)
        hierarchy.name = "real-iphone-catalogue-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        language.tap()
        let portuguese = application.buttons["Portuguese (Brazil)"]
        XCTAssertTrue(portuguese.waitForExistence(timeout: 5), application.debugDescription)
        portuguese.tap()
        let faber = application.cells["settings.speechModel.pt_BR-faber-medium"]
        reveal(faber, in: application, upward: false)
        XCTAssertTrue(faber.waitForExistence(timeout: 10), application.debugDescription)
        capture(application, name: "03-portuguese-faber-catalogue")
        // Preserve an installation completed while the earlier journey was paused.
        if !(faber.value as? String ?? "").contains("Installed") {
            faber.tap()
            let install = application.buttons["Install"]
            XCTAssertTrue(install.waitForExistence(timeout: 5), application.debugDescription)
            install.tap()
            XCTAssertTrue(application.alerts.buttons["Confirm installation"].waitForExistence(timeout: 5))
            application.alerts.buttons["Cancel"].tap()
            faber.tap()
            XCTAssertTrue(install.waitForExistence(timeout: 5))
            install.tap()
            confirmInstallation(in: application)
            waitUntil(seconds: 15) {
                application.alerts.firstMatch.exists ||
                    (faber.value as? String ?? "").contains("Downloading") ||
                    (faber.value as? String ?? "").contains("Preparing download")
            }
            capture(application, name: "04-installation-start-or-error")
            XCTAssertFalse(application.alerts.firstMatch.exists, application.debugDescription)
            faber.tap()
            let cancelDownload = application.buttons["Cancel download"]
            XCTAssertTrue(cancelDownload.waitForExistence(timeout: 10), application.debugDescription)
            cancelDownload.tap()
            waitUntil(seconds: 30) {
                (faber.value as? String)?.contains("Installation cancelled") == true
            }
            capture(application, name: "04-faber-download-cancelled")
            faber.tap()
            XCTAssertTrue(install.waitForExistence(timeout: 5))
            install.tap()
            confirmInstallation(in: application)
            waitUntil(seconds: 180) {
                let value = faber.value as? String ?? ""
                return value.contains("Installed") || value.contains("Installation completed")
            }
        }
        capture(application, name: "05-faber-installed")
        faber.tap()
        let sample = application.buttons["Hear voice sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5), application.debugDescription)
        sample.tap()
        let stop = application.alerts.buttons["Stop sample"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        XCTAssertFalse(stop.exists)
        faber.tap()
        sample.tap()
        XCTAssertTrue(application.staticTexts["Sample finished"].waitForExistence(timeout: 60), application.debugDescription)
        capture(application, name: "06-real-faber-sample-finished")
        stop.tap()
        let primary = application.cells["settings.tts.primary"]
        reveal(primary, in: application, upward: false)
        primary.tap()
        let system = application.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "System voice")).firstMatch
        XCTAssertTrue(system.waitForExistence(timeout: 5))
        system.tap()
        reveal(faber, in: application, upward: true)
        faber.tap()
        application.buttons["Use this voice"].tap()
        reveal(primary, in: application, upward: false)
        XCTAssertTrue((primary.value as? String)?.contains("Faber") == true)
        application.terminate()
        application.launch()
        dismissExpandedPlayer(in: application)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertTrue((primary.value as? String)?.contains("Faber") == true)
        capture(application, name: "07-primary-voice-persists-after-relaunch")
        #endif
    }

    func testPhysicalBookPronunciationConversionAndPlayback() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_AUDIOBOOK_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the isolated physical-device acceptance app")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical device only")
        #else
        continueAfterFailure = false
        let application = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3.uitests")
        app = application
        application.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-developmentSeedBook"]
        application.launch()
        dismissExpandedPlayer(in: application)
        let library = application.tabBars.buttons["Library"]
        if !library.waitForExistence(timeout: 5) {
            application.buttons["mainReader.browseLibrary"].tap()
        }
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let tile = application.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15), application.debugDescription)
        capture(application, name: "10-staged-epub-imported-in-library")
        tile.press(forDuration: 1.2)
        application.buttons["Download entire book"].tap()
        let pronunciation = application.buttons["bookDetail.pronunciation"]
        XCTAssertTrue(pronunciation.waitForExistence(timeout: 10), application.debugDescription)
        let listen = application.buttons["bookDetail.listen"]
        waitUntil(seconds: 180) { listen.label == "Resume audio" || application.alerts.firstMatch.exists }
        XCTAssertFalse(application.alerts.firstMatch.exists, application.debugDescription)
        capture(application, name: "11-real-initial-conversion-completed")
        pronunciation.tap()
        let editor = application.textViews["pronunciation.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        replaceText(in: editor, with: "invalid", app: application)
        application.buttons["Save"].tap()
        XCTAssertTrue(application.staticTexts["Use unique terms and nonempty pronunciations: original = spoken (up to 200 rules)."].waitForExistence(timeout: 5), application.debugDescription)
        capture(application, name: "12-pronunciation-invalid-rule-rejected")
        let savedRule = "Tolkien = Tólkien " + String(UUID().uuidString.prefix(4))
        replaceText(in: editor, with: savedRule, app: application)
        application.buttons["Save"].tap()
        XCTAssertFalse(editor.exists)
        pronunciation.tap()
        XCTAssertEqual(editor.value as? String, savedRule)
        editor.tap()
        editor.typeText(" discarded")
        application.buttons["Cancel"].tap()
        pronunciation.tap()
        XCTAssertEqual(editor.value as? String, savedRule)
        application.buttons["Cancel"].tap()
        capture(application, name: "13-pronunciation-save-and-cancel")
        application.buttons["bookDetail.download"].tap()
        let progress = application.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "generated")).firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 60), application.debugDescription)
        capture(application, name: "14-real-conversion-progress-and-eta")
        waitUntil(seconds: 180) { !progress.exists }
        application.buttons["Conversion log"].tap()
        let log = application.textViews.firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 5), application.debugDescription)
        waitUntil(seconds: 180) { (log.value as? String ?? "").contains("[Rust] conversion finished") }
        let logAttachment = XCTAttachment(string: log.value as? String ?? "")
        logAttachment.name = "real-iphone-conversion-log"
        logAttachment.lifetime = .keepAlways
        add(logAttachment)
        capture(application, name: "15-real-conversion-finished-log")
        application.navigationBars.buttons.element(boundBy: 0).tap()
        application.buttons["bookDetail.download"].tap()
        var replayLog = ""
        for _ in 0..<10 {
            application.buttons["Conversion log"].tap()
            XCTAssertTrue(log.waitForExistence(timeout: 5))
            replayLog = log.value as? String ?? ""
            if replayLog.range(of: "cached_segments=[1-9][0-9]*", options: .regularExpression) != nil,
               replayLog.contains("[Rust] conversion finished") { break }
            application.navigationBars.buttons.element(boundBy: 0).tap()
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertNotNil(replayLog.range(of: "cached_segments=[1-9][0-9]*", options: .regularExpression))
        XCTAssertTrue(replayLog.contains("[Rust] conversion finished"))
        let cacheAttachment = XCTAttachment(string: replayLog)
        cacheAttachment.name = "real-iphone-persistent-cache-log"
        cacheAttachment.lifetime = .keepAlways
        add(cacheAttachment)
        capture(application, name: "15-persistent-segment-cache-replay")
        application.navigationBars.buttons.element(boundBy: 0).tap()
        listen.tap()
        let fullTransport = application.buttons.matching(NSPredicate(
            format: "label IN %@ AND identifier != %@", ["Play", "Pause"], "miniPlayer.playPause"
        )).firstMatch
        XCTAssertTrue(application.buttons["fullPlayer.close"].waitForExistence(timeout: 30))
        waitUntil(seconds: 30) { fullTransport.label == "Pause" }
        let elapsed = application.staticTexts["fullPlayer.elapsed"]
        let initialTime = elapsed.label
        waitUntil(seconds: 8) { elapsed.label != initialTime }
        capture(application, name: "16-real-audio-playing-with-advancing-clock")
        fullTransport.tap()
        waitUntil(seconds: 5) { fullTransport.label == "Play" }
        Thread.sleep(forTimeInterval: 0.5)
        let pausedTime = elapsed.label
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(elapsed.label, pausedTime)
        capture(application, name: "17-paused-audio-and-clock")
        fullTransport.tap()
        waitUntil(seconds: 10) { fullTransport.label == "Pause" }
        waitUntil(seconds: 8) { elapsed.label != pausedTime }
        application.buttons["fullPlayer.close"].tap()
        let miniTransport = application.buttons["miniPlayer.playPause"]
        XCTAssertTrue(miniTransport.waitForExistence(timeout: 5))
        miniTransport.tap()
        waitUntil(seconds: 5) { miniTransport.label == "Play" }
        miniTransport.tap()
        waitUntil(seconds: 5) { miniTransport.label == "Pause" }
        application.buttons["miniPlayer.open"].tap()
        XCTAssertTrue(application.buttons["fullPlayer.close"].waitForExistence(timeout: 5))
        capture(application, name: "18-expanded-player-after-mini-player-pause-resume")
        fullTransport.tap()
        waitUntil(seconds: 5) { fullTransport.label == "Play" }
        application.buttons["fullPlayer.close"].tap()
        #endif
    }

    func testPhysicalInterruptedConversionOffersResume() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_AUDIOBOOK_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the isolated physical-device acceptance app")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical device only")
        #else
        continueAfterFailure = false
        let application = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3.uitests")
        app = application
        application.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-developmentSeedBook"]
        application.launch()
        dismissExpandedPlayer(in: application)
        openDownloadDetail(in: application)
        let pronunciation = application.buttons["bookDetail.pronunciation"]
        XCTAssertTrue(pronunciation.waitForExistence(timeout: 10))
        pronunciation.tap()
        let editor = application.textViews["pronunciation.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let rule = "Tolkien = Tólkien " + String(UUID().uuidString.prefix(4))
        replaceText(in: editor, with: rule, app: application)
        application.buttons["Save"].tap()
        application.buttons["bookDetail.download"].tap()
        let progress = application.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "generated")).firstMatch
        waitUntil(seconds: 60) {
            guard progress.exists,
                  let percent = Int(progress.label.split(separator: "%").first ?? "") else { return false }
            return percent >= 16 && percent < 90
        }
        capture(application, name: "20-conversion-before-process-interruption")
        application.terminate()
        application.launch()
        dismissExpandedPlayer(in: application)
        openDownloadDetail(in: application)
        XCTAssertTrue(pronunciation.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let resume = application.buttons["bookRecovery.resume"]
        capture(application, name: "21-reopened-interrupted-book")
        XCTAssertTrue(resume.waitForExistence(timeout: 5), application.debugDescription)
        let activeProgress = application.staticTexts.matching(NSPredicate(
            format: "label MATCHES %@", "^[0-9]+% (complete|generated.*)$"
        )).firstMatch
        XCTAssertFalse(activeProgress.exists, "Opening the interrupted book must preserve its recovery choice")
        resume.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        capture(application, name: "22-explicit-conversion-resume")
        waitUntil(seconds: 180) { !progress.exists }
        XCTAssertFalse(resume.exists)
        application.buttons["Conversion log"].tap()
        let log = application.textViews.firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 5))
        XCTAssertTrue((log.value as? String ?? "").contains("[Rust] conversion finished"))
        let attachment = XCTAttachment(string: log.value as? String ?? "")
        attachment.name = "real-iphone-recovered-conversion-log"
        attachment.lifetime = .keepAlways
        add(attachment)
        capture(application, name: "23-recovered-conversion-completed")
        #endif
    }

    private func openDownloadDetail(in app: XCUIApplication) {
        let library = app.tabBars.buttons["Library"]
        if !library.waitForExistence(timeout: 3) {
            app.buttons["mainReader.browseLibrary"].tap()
        }
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        let tile = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.press(forDuration: 1.2)
        app.buttons["Download entire book"].tap()
    }

    private func replaceText(in editor: XCUIElement, with text: String, app: XCUIApplication) {
        editor.tap()
        if !(editor.value as? String ?? "").isEmpty {
            editor.press(forDuration: 1.1)
            let menuItem = app.menuItems["Select All"]
            let button = app.buttons["Select All"]
            if menuItem.waitForExistence(timeout: 1) {
                menuItem.tap()
            } else {
                XCTAssertTrue(button.waitForExistence(timeout: 2), app.debugDescription)
                button.tap()
            }
        }
        editor.typeText(text)
        XCTAssertEqual(editor.value as? String, text, app.debugDescription)
    }

    private func dismissExpandedPlayer(in app: XCUIApplication) {
        let close = app.buttons["fullPlayer.close"]
        if close.waitForExistence(timeout: 3) {
            close.tap()
            waitUntil(seconds: 5) { !close.exists }
        }
    }

    private func confirmInstallation(in app: XCUIApplication) {
        let confirm = app.alerts.buttons["Confirm installation"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitUntil(seconds: 5) { !confirm.exists }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool) {
        let table = app.tables.firstMatch
        for _ in 0..<12 {
            let viewport = table.frame.intersection(app.frame).insetBy(dx: 0, dy: 12)
            if element.exists {
                let frame = element.frame
                if !frame.isEmpty && !frame.isInfinite && viewport.contains(frame) { return }
            }
            if upward { table.swipeUp() } else { table.swipeDown() }
        }
        XCTFail("The requested real-app control did not enter the visible viewport")
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline {
                XCTFail("The real application did not reach the expected state")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func capture(_ application: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
