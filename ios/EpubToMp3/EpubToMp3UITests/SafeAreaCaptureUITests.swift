import XCTest

/// Device regression for "reader ignores the safe area when the top/bottom
/// bars are hidden". With chrome hidden the page text must still clear the
/// status bar / notch at the top and the home indicator at the bottom.
///
/// A test-only probe exposes the first visible glyph's actual window position
/// and page range. This catches a sibling navigation bar overlapping text,
/// which the outer UITextView frame cannot reveal on its own.
@MainActor
final class SafeAreaCaptureUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testReaderRespectsSafeAreaWithChromeHidden() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestFixture"]
        // Pin paginated mode: this test inspects a single page's text frame.
        // In scroll mode the whole book is rendered, so enumerating every text
        // element takes minutes and the run times out.
        app.launchArguments += [
            "-uiTestResetReaderPosition", "-uiTestReaderLayout", "paginated",
            "-uiTestPaginationProbe",
        ]
        app.launch()

        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: 20) else {
            throw XCTSkip("No book in library.")
        }
        firstBook.tap()
        guard app.buttons["reader.search"].firstMatch.waitForExistence(timeout: 20) else {
            throw XCTSkip("Reader did not open.")
        }
        sleep(2)
        attach(app, "01-chrome-shown")

        let window = app.windows.firstMatch
        let probe = app.staticTexts["reader.paginationProbe"].firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 10), "reader must expose glyph geometry for this test")

        func values() -> [String: Int] {
            Dictionary(uniqueKeysWithValues: probe.label.split(separator: ";").compactMap { item in
                let pair = item.split(separator: "=", maxSplits: 1)
                guard pair.count == 2, let value = Int(pair[1]) else { return nil }
                return (String(pair[0]), value)
            })
        }

        let shown = values()
        XCTAssertGreaterThan(shown["total"] ?? 0, 1, "long fixture must produce multiple reachable pages")
        XCTAssertGreaterThanOrEqual(shown["firstY"] ?? 0, Int(window.frame.minY),
            "chrome shown: first glyph must be in the window")
        let close = app.buttons["reader.close"].firstMatch
        XCTAssertTrue(close.exists, "chrome shown: host navigation bar must be visible")
        XCTAssertGreaterThanOrEqual(shown["firstY"] ?? 0, Int(close.frame.maxY.rounded()),
            "chrome shown: no glyph may render behind the host navigation bar")

        // Hide chrome.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        attach(app, "02-chrome-hidden")
        XCTAssertFalse(close.exists, "chrome hidden: the host navigation bar must be removed")

        // Turn a page to persist reading progress. This triggers the host's
        // UserDefaults-driven render path that previously resurrected the
        // navigation bar above the immersive reader.
        let nextPage = app.buttons["reader.pageTurn.right"].firstMatch
        XCTAssertTrue(nextPage.waitForExistence(timeout: 5))
        nextPage.tap()
        sleep(1)

        let hidden = values()
        XCTAssertFalse(close.exists, "a host re-render must not restore navigation over immersive text")
        XCTAssertEqual(hidden["viewportTop"], hidden["safeTop"],
            "chrome hidden: the text viewport must begin at the real safe area")
        XCTAssertEqual(hidden["viewportBottom"], hidden["safeBottom"],
            "chrome hidden: the text viewport must end at the home-indicator safe area")
        XCTAssertGreaterThan(hidden["first"] ?? 0, shown["first"] ?? -1,
            "next page must advance the visible character range")
        XCTAssertGreaterThan(hidden["total"] ?? 0, 1, "page count must remain valid after re-render")
        XCTAssertNotEqual(hidden["viewportHeight"], shown["viewportHeight"],
            "chrome transition must recalculate the paginated viewport")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
