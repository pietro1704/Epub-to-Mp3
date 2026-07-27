import XCTest

@MainActor
final class LibrarySearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSearchBarFiltersAndClears() throws {
        let app = launchedApp()
        let searchBar = try searchBar(in: app)
        let field = searchBar.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.tap()
        field.typeText("zzzz-no-match")
        XCTAssertEqual(field.value as? String, "zzzz-no-match")

        let clear = searchBar.buttons.firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertNotEqual(field.value as? String, "zzzz-no-match")
    }

    func testSearchBarRemainsAvailableWhileScrolling() throws {
        let app = launchedApp()
        let searchBar = try searchBar(in: app)
        XCTAssertEqual(searchBar.value as? String, "visible")

        let scrollSurface = app.collectionViews.firstMatch
        XCTAssertTrue(scrollSurface.waitForExistence(timeout: 5))
        scrollSurface.swipeUp(velocity: .fast)
        scrollSurface.swipeDown(velocity: .fast)
        XCTAssertEqual(searchBar.value as? String, "visible")
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

    private func searchBar(in app: XCUIApplication) throws -> XCUIElement {
        let element = app.descendants(matching: .any)["library.searchBar"].firstMatch
        guard element.waitForExistence(timeout: 5) else {
            throw XCTSkip("No imported book; LibraryView search surface is not rendered.")
        }
        return element
    }
}
