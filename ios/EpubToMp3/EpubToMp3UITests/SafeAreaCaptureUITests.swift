import XCTest

/// Device regression for "reader ignores the safe area when the top/bottom
/// bars are hidden". With chrome hidden the page text must still clear the
/// status bar / notch at the top and the home indicator at the bottom.
///
/// We can't inspect glyph positions, but the hosted page text view is a
/// queryable element. We assert its frame stays inside the window's safe
/// region (approximated by a conservative top inset) in BOTH chrome states,
/// and attach screenshots for manual confirmation.
@MainActor
final class SafeAreaCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testReaderRespectsSafeAreaWithChromeHidden() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // Pin paginated mode: this test inspects a single page's text frame.
        // In scroll mode the whole book is rendered, so enumerating every text
        // element takes minutes and the run times out.
        app.launchArguments += ["-uiTestResetReaderPosition", "-uiTestReaderLayout", "paginated"]
        app.launch()

        let firstBook = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else {
            throw XCTSkip("No book in library.")
        }
        firstBook.tap()
        guard app.buttons["Buscar no livro"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open.")
        }
        sleep(2)
        attach(app, "01-chrome-shown")

        // The reading text view: the largest text element in the reader.
        let window = app.windows.firstMatch
        let winFrame = window.frame
        // Conservative portrait status-bar/notch height. The first line of
        // text must start below this on a notched phone in BOTH chrome states.
        let statusBarFloor: CGFloat = 44

        func topMostTextMinY() -> CGFloat? {
            // UITextView surfaces as a textView (and/or staticText) element.
            let texts = app.textViews.allElementsBoundByIndex
                + app.staticTexts.allElementsBoundByIndex
            let onScreen = texts
                .filter { $0.exists && $0.frame.height > 8 && $0.frame.width > 40 }
                // Ignore the hidden probe overlay and tiny chrome labels.
                .filter { $0.frame.minY > 1 && $0.frame.maxY < winFrame.height }
            return onScreen.map(\.frame.minY).min()
        }

        if let shownMinY = topMostTextMinY() {
            XCTAssertGreaterThanOrEqual(shownMinY, statusBarFloor,
                "chrome shown: text must start below the status bar (minY=\(shownMinY))")
        }

        // Hide chrome.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        attach(app, "02-chrome-hidden")

        // The critical assertion: with chrome hidden, text MUST still clear
        // the status bar — this is the exact bug the user reported.
        if let hiddenMinY = topMostTextMinY() {
            XCTAssertGreaterThanOrEqual(hiddenMinY, statusBarFloor,
                "chrome HIDDEN: text must STILL clear the status bar / notch (minY=\(hiddenMinY))")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
