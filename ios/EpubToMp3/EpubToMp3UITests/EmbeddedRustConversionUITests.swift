import XCTest

@MainActor
final class EmbeddedRustConversionUITests: XCTestCase {
    func testSeedBookOpensWithEmbeddedRustReaderAndNoClippedLines() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        app.launch()

        let bookTile = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        XCTAssertTrue(bookTile.waitForExistence(timeout: 30), "The seeded book must be visible in the library.")
        let readerHarness = ReaderModesHarness(app: app)
        let configuration = ReaderModesHarness.LaunchConfiguration(
            source: .seededLOTR,
            layout: "paginated",
            smallFont: false,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true,
            additionalArguments: ["-uiTestRustConversionProbe"]
        )
        _ = readerHarness.launch(configuration)
        try readerHarness.openBook(titleContaining: "Lord of the Rings")

        let reader = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The seeded EPUB must open without backend parsing.")
        XCTAssertTrue(app.buttons["reader.search"].waitForExistence(timeout: 10))

        let unavailableError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Embedded converter artifact is unavailable")
        ).firstMatch
        XCTAssertFalse(unavailableError.exists, "Opening the EPUB must not report a missing embedded converter.")

        let backendError = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "backend URL")
        ).firstMatch
        XCTAssertFalse(backendError.waitForExistence(timeout: 1), "Conversion must not fall back to a backend URL.")

        readerHarness.assertNoClippedLines(scenario: "seeded EPUB initial page")
    }
}
