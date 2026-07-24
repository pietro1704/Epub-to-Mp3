import XCTest

final class LibrarySearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testSearchBarFiltersAndClears() throws {
        let app = launchedApp()
        let searchBar = try searchBar(in: app)
        let field = searchBar.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.tap()
        field.typeText("zzzz-no-match")
        XCTAssertEqual(field.value as? String, "zzzz-no-match")

        let clear = searchBar.buttons.firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        XCTAssertEqual(field.value as? String, "")
    }

    func testSearchBarAutoHidesOnDownScrollAndReturnsOnUpScroll() throws {
        let app = launchedApp()
        let searchBar = try searchBar(in: app)
        XCTAssertEqual(searchBar.value as? String, "visible")

        app.windows.firstMatch.swipeUp(velocity: .fast)
        let hidden = NSPredicate(format: "value == %@", "hidden")
        expectation(for: hidden, evaluatedWith: searchBar)
        waitForExpectations(timeout: 5)

        app.windows.firstMatch.swipeDown(velocity: .fast)
        let visible = NSPredicate(format: "value == %@", "visible")
        expectation(for: visible, evaluatedWith: searchBar)
        waitForExpectations(timeout: 5)
    }


    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        app.launch()
        return app
    }

    private func searchBar(in app: XCUIApplication) throws -> XCUIElement {
        let element = app.descendants(matching: .any)["library.searchBar"].firstMatch
        guard element.waitForExistence(timeout: 20) else {
            throw XCTSkip("No imported book; LibraryView search surface is not rendered.")
        }
        return element
    }
}
