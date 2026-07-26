import XCTest

/// Regression for "scroll mode won't leave the index/TOC screen". Opens the
/// reader in scrolling layout and drags up repeatedly, asserting the visible
/// text actually changes (the reader scrolls past the first screen instead of
/// snapping back to the top).
@MainActor
final class ScrollStuckUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// A cheap fingerprint of what's on screen: the labels of the first few
    /// static texts. If scrolling works this changes; if stuck it stays equal.
    private func screenFingerprint(_ app: XCUIApplication) -> String {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(6)
        return texts.map { $0.label }.joined(separator: "¦")
    }

    func testScrollLeavesTheFirstScreen() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Force scrolling layout, but DO NOT reset position — mirror the real
        // user entry as closely as the harness allows.
        app.launchArguments += ["-uiTestReaderLayout", "scrolling"]
        app.launch()

        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else { throw XCTSkip("No book.") }
        firstBook.tap()
        guard app.buttons["Buscar no livro"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open.")
        }
        sleep(2)

        let before = screenFingerprint(app)

        // Drag up several times.
        let window = app.windows.firstMatch
        for _ in 0..<4 { window.swipeUp(velocity: .fast); usleep(400_000) }
        sleep(1)

        let after = screenFingerprint(app)
        XCTAssertNotEqual(before, after,
                          "scrolling up must move past the first screen (index/TOC), but the content did not change")
    }
}
