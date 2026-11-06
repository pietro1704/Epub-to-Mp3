import XCTest

@MainActor
final class AuditVoicePreviewJourneyTests: XCTestCase {
    func testInstalledForeignLanguageVoiceCompletesSampleWithoutChangingNarration() throws {
        guard ProcessInfo.processInfo.environment["EPUB2MP3_PHYSICAL_APP_BUNDLE_ID"] == "com.pietrocode.epubtomp3" else {
            throw XCTSkip("Requires the installed physical app and Faber model")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.pietrocode.epubtomp3")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-uiTestResetActiveReader", "-player.presentation.expanded.v1", "NO"]
        app.launch()
        defer { app.terminate() }
        for identifier in ["fullPlayer.close", "reader.close", "mainReader.browseLibrary"] {
            let button = app.buttons[identifier].firstMatch
            if button.exists && button.isHittable { button.tap() }
        }
        let settings = app.tabBars.buttons["Settings"].firstMatch
        if !settings.waitForExistence(timeout: 3) {
            let browse = app.buttons["mainReader.browseLibrary"].firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 10))
            browse.tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let table = app.tables.firstMatch
        let disclosure = app.cells["settings.speechModels.disclosure"].firstMatch
        for _ in 0..<12 where !disclosure.exists || !table.frame.contains(disclosure.frame) { table.swipeUp() }
        XCTAssertTrue(disclosure.isHittable)
        if disclosure.value as? String == "Collapsed" { disclosure.tap() }
        let model = app.cells["settings.speechModel.pt_BR-faber-medium"].firstMatch
        for _ in 0..<12 where !model.exists || !table.frame.contains(model.frame) { table.swipeUp() }
        XCTAssertTrue(model.isHittable)
        XCTAssertTrue((model.value as? String ?? "").contains("Installed"), "Model downloads are outside this journey")
        let before = model.value as? String
        model.tap()
        let sample = app.buttons["Hear voice sample"].firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        XCTAssertTrue(app.buttons["Stop sample"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sample finished"].firstMatch.waitForExistence(timeout: 60), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "installed-faber-own-language-preview-completed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["Stop sample"].firstMatch.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, before)
    }
}
