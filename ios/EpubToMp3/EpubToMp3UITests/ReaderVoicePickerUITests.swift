import XCTest

@MainActor
final class ReaderVoicePickerUITests: XCTestCase {
    func testMoreVoiceModelsShowsChoicesImmediatelyAndCancelReturnsToReader() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-developmentSeedBook", "-uiTestResetActiveReader", "-uiTestChromeToggle",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let harness = ReaderModesHarness(app: app)
        let more = app.buttons["reader.more"].firstMatch
        if !more.waitForExistence(timeout: 3) {
            try harness.openBook(titleContaining: "Lord", timeout: 60)
        }
        XCTAssertTrue(app.images["reader.loadingCover"].firstMatch.waitForNonExistence(timeout: 60))
        harness.toggleChromeAndSettle(visible: true, timeout: 10)

        more.tap()
        let command = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "reader.voiceModels", "Voice models")).firstMatch
        if command.waitForExistence(timeout: 3), command.isHittable { command.tap() }
        else {
            let item = app.menuItems["Voice models"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3))
            item.tap()
        }

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "The first Voice models action must show the voice picker.")
        let current = sheet.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "✓ ")).firstMatch
        XCTAssertTrue(current.exists, "The active voice must be marked before tapping another control.")
        XCTAssertTrue(sheet.buttons["Model downloads"].exists, "Downloads require a separate action.")
        let cancel = sheet.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.exists)
        cancel.tap()

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        XCTAssertTrue(more.isHittable)
    }
}
