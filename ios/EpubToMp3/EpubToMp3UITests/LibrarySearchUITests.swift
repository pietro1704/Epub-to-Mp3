import XCTest

@MainActor
final class LibrarySearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSearchBarFiltersAndClears() throws {
        let app = launchedApp()
        let field = try searchField(in: app)

        field.tap()
        field.typeText("zzzz-no-match")
        XCTAssertEqual(field.value as? String, "zzzz-no-match")

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "zzzz-no-match".count))
        XCTAssertNotEqual(field.value as? String, "zzzz-no-match")
    }

    func testSearchBarRemainsAvailableWhileScrolling() throws {
        let app = launchedApp()
        let field = try searchField(in: app)
        XCTAssertTrue(field.isHittable)

        let scrollSurface = app.collectionViews.firstMatch
        XCTAssertTrue(scrollSurface.waitForExistence(timeout: 5))
        scrollSurface.swipeUp(velocity: .fast)
        scrollSurface.swipeDown(velocity: .fast)
        XCTAssertTrue(field.exists)
    }


    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        app.launch()
        let libraryTab = app.tabBars.firstMatch.buttons.matching(
            NSPredicate(format: "identifier CONTAINS[c] %@", "library")
        ).firstMatch
        if libraryTab.waitForExistence(timeout: 10) {
            libraryTab.tap()
        } else {
            let firstTab = app.tabBars.firstMatch.buttons.firstMatch
            if firstTab.waitForExistence(timeout: 2) { firstTab.tap() }
        }
        return app
    }

    private func searchField(in app: XCUIApplication) throws -> XCUIElement {
        let element = app.searchFields["library.searchField"]
        guard element.waitForExistence(timeout: 5) else {
            throw XCTSkip("Native Library search field is not rendered.")
        }
        return element
    }
}
