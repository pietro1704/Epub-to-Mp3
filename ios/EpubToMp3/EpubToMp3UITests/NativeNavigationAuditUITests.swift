import XCTest

@MainActor
final class NativeNavigationAuditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEnglishNavigationPortraitAndLandscape() {
        audit(language: "en", locale: "en_US", accessibilityText: false,
              library: "Library", settings: "Settings", convert: "Convert",
              pickFile: "Pick EPUB or PDF", cancel: "Cancel", voice: "Voice (optional)")
    }

    func testPortugueseNavigationWithAccessibilityText() {
        audit(language: "pt-BR", locale: "pt_BR", accessibilityText: true,
              library: "Biblioteca", settings: "Ajustes", convert: "Converter",
              pickFile: "Escolher EPUB ou PDF", cancel: "Cancelar", voice: "Voz (opcional)")
    }

    private func audit(language: String, locale: String, accessibilityText: Bool,
                       library: String, settings: String, convert: String,
                       pickFile: String, cancel: String, voice: String) {
        let originalOrientation = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = .portrait
        defer {
            XCUIDevice.shared.orientation = originalOrientation == .unknown ? .portrait : originalOrientation
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestFixture", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchArguments += ["-AppleInterfaceStyle", accessibilityText ? "Dark" : "Light"]
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 10))

        let libraryTab = tabs.buttons[library]
        assertVisible(libraryTab, app: app)
        libraryTab.tap()
        let search = app.searchFields["library.searchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        assertVisible(search, app: app)
        attach("\(language)-library-portrait", app: app)

        let settingsTab = tabs.buttons[settings]
        assertVisible(settingsTab, app: app)
        settingsTab.tap()
        let settingsTable = app.tables.firstMatch
        XCTAssertTrue(settingsTable.waitForExistence(timeout: 5))
        attach("\(language)-settings-top", app: app)
        let diagnostics = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", language == "en" ? "Record streaming diagnostics" : "Gravar diagnóstico de streaming")).firstMatch
        scrollTo(diagnostics, in: settingsTable, app: app)
        assertVisible(diagnostics, app: app)
        attach("\(language)-settings-bottom", app: app)
        for _ in 0..<4 { settingsTable.swipeDown(velocity: .fast) }

        let convertTab = tabs.buttons[convert]
        assertVisible(convertTab, app: app)
        convertTab.tap()
        let convertTable = app.tables.firstMatch
        XCTAssertTrue(convertTable.waitForExistence(timeout: 5))
        let pickerRow = app.cells.containing(.staticText, identifier: pickFile).firstMatch
        scrollTo(pickerRow, in: convertTable, app: app, velocity: .slow)
        assertVisible(pickerRow, app: app)
        attach("\(language)-convert-portrait", app: app)
        pickerRow.tap()
        let cancelButton = app.buttons[cancel].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Native file picker must expose Cancel")
        assertVisible(cancelButton, app: app)
        attach("\(language)-file-picker", app: app)
        cancelButton.tap()
        XCTAssertTrue(pickerRow.waitForExistence(timeout: 5))

        XCUIDevice.shared.orientation = .landscapeLeft
        let voiceField = app.textFields[voice].firstMatch
        scrollTo(voiceField, in: convertTable, app: app, velocity: .slow)
        assertVisible(voiceField, app: app)
        attach("\(language)-convert-landscape", app: app)
        XCUIDevice.shared.orientation = .portrait
        assertVisible(libraryTab, app: app)
        libraryTab.tap()
        assertVisible(search, app: app)
        attach("\(language)-library-return", app: app)
    }

    private func scrollTo(_ element: XCUIElement, in surface: XCUIElement, app: XCUIApplication, velocity: XCUIGestureVelocity = .fast) {
        let viewport = surface.frame.intersection(app.windows.firstMatch.frame)
        let navigation = app.navigationBars.firstMatch
        let top = max(viewport.minY, navigation.exists ? navigation.frame.maxY : viewport.minY)
        var bottom = min(viewport.maxY, app.tabBars.firstMatch.frame.minY)
        let miniPlayer = app.buttons["miniPlayer.open"].firstMatch
        if miniPlayer.exists && miniPlayer.frame.intersects(viewport) {
            bottom = min(bottom, miniPlayer.frame.minY - 8)
        }
        let height = max(40, bottom - top)
        let origin = app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: viewport.midX, dy: top + height * 0.85))
        let end = origin.withOffset(CGVector(dx: viewport.midX, dy: top + height * 0.15))
        for _ in 0..<60 {
            if element.exists && element.isHittable { return }
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
        }
        XCTAssertTrue(element.exists && element.isHittable, "Control must be reachable by scrolling: \(element)")
    }

    private func assertVisible(_ element: XCUIElement, app: XCUIApplication,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(element.isHittable, "Control must remain interactive", file: file, line: line)
        XCTAssertGreaterThan(element.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(element.frame.height, 0, file: file, line: line)
        let viewport = app.windows.firstMatch.frame
        XCTAssertTrue(viewport.intersects(element.frame) && element.frame.minX >= viewport.minX - 1 && element.frame.maxX <= viewport.maxX + 1,
                      "Control \(element.frame) must fit within the current window \(viewport)", file: file, line: line)
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
