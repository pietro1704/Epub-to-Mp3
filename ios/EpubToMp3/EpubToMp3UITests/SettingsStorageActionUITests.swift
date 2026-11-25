import XCTest

@MainActor
final class SettingsStorageActionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnglishStorageConfirmationsMatchTheirRowsAndCancel() {
        verifyConfirmations(language: "en", locale: "en_US", settings: "Settings",
                            temporaryRow: "Clear temporary generated audio", temporaryTitle: "Clear temporary audio?",
                            temporaryMessage: "Generated audio that was not downloaded will be removed. Downloaded audiobook audio will remain.",
                            downloadsRow: "Clear all book downloads", downloadsTitle: "Clear all downloads?",
                            downloadsMessage: "All offline MP3s and generated chapter audio caches will be deleted.",
                            destructive: "Delete All", cancel: "Cancel")
    }

    func testPortugueseStorageConfirmationsMatchTheirRowsAndCancel() {
        verifyConfirmations(language: "pt-BR", locale: "pt_BR", settings: "Ajustes",
                            temporaryRow: "Limpar áudio temporário gerado", temporaryTitle: "Limpar áudio temporário?",
                            temporaryMessage: "O áudio gerado que não foi baixado será removido. O áudio baixado dos audiolivros permanecerá.",
                            downloadsRow: "Limpar todos os downloads dos livros", downloadsTitle: "Limpar todos os downloads?",
                            downloadsMessage: "Todos os MP3s offline e caches de áudio gerados dos capítulos serão apagados.",
                            destructive: "Apagar tudo", cancel: "Cancelar")
    }

    private func verifyConfirmations(language: String, locale: String, settings: String,
                                     temporaryRow: String, temporaryTitle: String, temporaryMessage: String,
                                     downloadsRow: String, downloadsTitle: String, downloadsMessage: String,
                                     destructive: String, cancel: String) {
        let app = XCUIApplication()
        // Argument-domain override avoids opening the reader without changing
        // saved book progress or installing a library/playback fixture.
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                               "-currentlyReadingBookID", ""]
        app.launch()
        defer { app.terminate() }
        let closePlayer = app.buttons["fullPlayer.close"].firstMatch
        if closePlayer.waitForExistence(timeout: 2) {
            closePlayer.tap()
            XCTAssertTrue(closePlayer.waitForNonExistence(timeout: 5))
        }
        let settingsTab = app.tabBars.firstMatch.buttons[settings]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10))
        settingsTab.tap()
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        for (rowLabel, title, message) in [(temporaryRow, temporaryTitle, temporaryMessage),
                                            (downloadsRow, downloadsTitle, downloadsMessage)] {
            let row = table.cells.containing(.staticText, identifier: rowLabel).firstMatch
            for _ in 0..<10 {
                if row.exists && row.isHittable { break }
                table.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(row.exists && row.isHittable, "Settings must expose \(rowLabel) on the SE viewport.")
            row.tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(alert.staticTexts[title].exists, "The selected row must present its own cleanup scope.")
            XCTAssertTrue(alert.staticTexts[message].exists)
            XCTAssertTrue(alert.buttons[destructive].exists)
            let cancelButton = alert.buttons[cancel]
            XCTAssertTrue(cancelButton.isHittable)
            attach("\(language)-\(title)", app: app)
            cancelButton.tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 5))
            XCTAssertTrue(table.exists && row.exists, "Cancel must return to the same Settings screen.")
            attach("\(language)-cancelled-\(title)", app: app)
        }
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
