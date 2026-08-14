import XCTest

@MainActor
final class ReaderModesHarness {
    enum Source {
        case fixture
        case seededLOTR
    }

    struct LaunchConfiguration {
        let source: Source
        let layout: String
        let smallFont: Bool
        let chromeToggleEnabled: Bool
        let paginationProbeEnabled: Bool
        let flickerProbeEnabled: Bool
        let additionalArguments: [String]

        init(
            source: Source,
            layout: String,
            smallFont: Bool,
            chromeToggleEnabled: Bool,
            paginationProbeEnabled: Bool,
            flickerProbeEnabled: Bool = false,
            additionalArguments: [String] = []
        ) {
            self.source = source
            self.layout = layout
            self.smallFont = smallFont
            self.chromeToggleEnabled = chromeToggleEnabled
            self.paginationProbeEnabled = paginationProbeEnabled
            self.flickerProbeEnabled = flickerProbeEnabled
            self.additionalArguments = additionalArguments
        }

        static let paginatedFixture = LaunchConfiguration(
            source: .fixture,
            layout: "paginated",
            smallFont: false,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true
        )

        static let paginatedNativeLOTR = LaunchConfiguration(
            source: .seededLOTR,
            layout: "paginated",
            smallFont: false,
            chromeToggleEnabled: true,
            paginationProbeEnabled: true
        )
    }

    struct PaginationMetrics {
        let values: [String: Int]

        var page: Int? { values["page"] }
        var total: Int? { values["total"] }
        var clippedLineCount: Int? { values["clippedLineCount"] }
    }

    let app: XCUIApplication

    init(app: XCUIApplication = XCUIApplication()) {
        self.app = app
    }

    @discardableResult
    func launch(_ configuration: LaunchConfiguration = .paginatedFixture) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        switch configuration.source {
        case .fixture:
            app.launchArguments += ["-uiTestFixture", "-uiTestResetReaderPosition"]
        case .seededLOTR:
            app.launchArguments += ["-developmentSeedBook", "-uiTestPlaybackFixture"]
        }
        app.launchArguments += ["-uiTestReaderLayout", configuration.layout]
        if configuration.chromeToggleEnabled {
            app.launchArguments += ["-uiTestChromeToggle"]
        }
        if configuration.paginationProbeEnabled {
            app.launchArguments += ["-uiTestPaginationProbe"]
        }
        if configuration.flickerProbeEnabled {
            app.launchArguments += ["-uiTestFlickerProbe"]
        }
        app.launchArguments += ["-uiTestNoPageTurnOverlay"]
        if configuration.smallFont {
            app.launchArguments += ["-uiTestReaderFontSize", "0", "-uiTestReaderOverrideFontSize"]
        }
        app.launchArguments += configuration.additionalArguments
        app.launch()
        return app
    }

    func openBook(timeout: TimeInterval = 20) throws {
        let firstBook = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "library.bookTile.")
        ).firstMatch
        guard firstBook.waitForExistence(timeout: timeout) else {
            throw XCTSkip("No book is available for the reader test.")
        }
        if !firstBook.isHittable {
            let closeReader = app.buttons["reader.close"].firstMatch
            guard closeReader.waitForExistence(timeout: 5) else {
                throw XCTSkip("The library is covered by an unknown surface.")
            }
            closeReader.tap()
            XCTAssertTrue(
                firstBook.waitForExistence(timeout: 5) && firstBook.isHittable,
                "Closing a restored reader must reveal the fixture library."
            )
        }
        firstBook.tap()
        XCTAssertTrue(
            app.buttons["reader.search"].firstMatch.waitForExistence(timeout: timeout),
            "The selected book must open in the native reader."
        )
    }

    func toggleChrome() {
        let viewport = app.scrollViews["reader.viewport"].firstMatch
        XCTAssertTrue(viewport.waitForExistence(timeout: 5), "The reader viewport must be available.")
        viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func toggleChromeAndSettle(visible: Bool, timeout: TimeInterval = 3) {
        guard chromeIsVisible != visible else { return }
        toggleChrome()
        XCTAssertTrue(
            waitUntil(timeout: timeout) { self.chromeIsVisible == visible },
            "The reader chrome must settle to the requested state."
        )
    }

    func turnPage(forward: Bool, timeout: TimeInterval = 3) {
        let button = app.buttons[forward ? "reader.pageTurn.right" : "reader.pageTurn.left"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: timeout), "The page-turn control must be available.")
        let previousPage = paginationMetrics?.page
        button.tap()
        if let previousPage {
            XCTAssertTrue(
                waitUntil(timeout: timeout) { self.paginationMetrics?.page != previousPage },
                "The page indicator must change after an explicit page turn."
            )
        }
    }

    var chromeIsVisible: Bool {
        app.buttons["reader.search"].firstMatch.exists
    }

    var paginationMetrics: PaginationMetrics? {
        let probe = app.staticTexts["reader.paginationProbe"].firstMatch
        guard probe.waitForExistence(timeout: 5) else { return nil }
        let values = Dictionary(uniqueKeysWithValues: probe.label.split(separator: ";").compactMap { item in
            let pair = item.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            return (String(pair[0]), value)
        })
        return PaginationMetrics(values: values)
    }

    func assertNoClippedLines(
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let metrics = paginationMetrics,
              let firstY = metrics.values["firstCompleteY"],
              let lastY = metrics.values["lastCompleteY"],
              let clippedLineCount = metrics.clippedLineCount,
              let viewportTop = metrics.values["viewportTop"],
              let viewportBottom = metrics.values["viewportBottom"] else {
            return XCTFail("\(scenario): pagination probe is incomplete", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(
            firstY,
            viewportTop - 1,
            "\(scenario): the first visible line is cut above the viewport (\(metrics.values))",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            lastY,
            viewportBottom + 1,
            "\(scenario): the last visible line is cut below the viewport (\(metrics.values))",
            file: file,
            line: line
        )
        XCTAssertEqual(
            clippedLineCount,
            0,
            "\(scenario): a TextKit line fragment is cut by the viewport (\(metrics.values))",
            file: file,
            line: line
        )
    }
}
