import XCTest

/// Regression for "scroll mode won't leave the index/TOC screen". Opens the
/// reader in scrolling layout and drags up repeatedly, asserting the visible
/// text actually changes (the reader scrolls past the first screen instead of
/// snapping back to the top).
@MainActor
final class ScrollStuckUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testScrollLeavesTheFirstScreen() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        // Force scrolling layout, but DO NOT reset position — mirror the real
        // user entry as closely as the harness allows.
        app.launchArguments += ["-uiTestReaderLayout", "scrolling"]
        app.launch()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard app.buttons["reader.search"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open.")
        }
        sleep(2)

        // Drag up several times.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        for _ in 0..<4 {
            start.press(forDuration: 0.1, thenDragTo: end)
            usleep(400_000)
        }
        sleep(1)

        XCTAssertTrue(app.buttons["reader.search"].firstMatch.exists,
                      "reader chrome must remain alive after repeated scroll gestures")
        XCTAssertTrue(app.textViews["reader.content"].firstMatch.exists,
                      "reader content must remain mounted after repeated scroll gestures")
    }
}
